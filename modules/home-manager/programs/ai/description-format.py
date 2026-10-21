#!/usr/bin/env python3
"""Offline description checks and an always-allow observation hook (ADR-0101).

This is a Markdown subset and a direct-command classifier, not a renderer or
shell interpreter. No subprocess, Git configuration or environment lookup is
used. Direct gh writes require an explicit host/owner/repo selector or full
item URL; unresolved targets are unsupported without inspecting their bodies.
"""

import argparse
import collections
import contextlib
import datetime as dt
import fcntl
import json
import os
import re
import stat
import sys
import time
import urllib.parse


VERSION = 1
MAX_DIAGNOSTICS = 5
MAX_BODY = 256 * 1024
MAX_INPUT = 2 * 1024 * 1024
MAX_CONFIG = 128 * 1024
LOG_BYTES = 1024 * 1024
LOG_FILES = 4  # Active file plus three older files, all under one lock.
DELIVERIES = ("direct", "claude-user", "codex-user", "codex-managed")
LABELS = {
    "issue": ("Status", "Next", "Owner", "Why", "Plan", "Done when"),
    "pr": ("What", "Why", "Risk", "Verification", "After merge"),
}
HINTS = {
    "opening-order": "Start with the required bold labels in order, with no extra opening label.",
    "label-position": "Put each required label once at the top level, outside lists and quotes.",
    "empty-value": "Give every required label a nonempty value.",
    "paragraph-separation": "Put a blank line before each opening label after the first.",
    "plan-numbered": "Use a numbered Plan whose first step is 1.",
    "done-checklist": "Use a checklist for Done when.",
    "verification-line": "Keep Verification on one nonempty line.",
    "markdown-heading": "Use bold labels instead of Markdown headings, including inside details.",
    "summary-spacing": "Put a blank line after the closing summary tag.",
    "input-limit": "Keep the description within the validator's input limit.",
    "unsupported-body": "Supply a literal body, or use a regular --body-file in a direct gh write.",
    "unsupported-target": "Supply an explicit host/owner/repo with -R/--repo, or a full item URL.",
}
TOP_LABEL = re.compile(r"^\*\*([^*\n]+):\*\*(?:[ \t]+(.*)|[ \t]*)$")
ANY_LABEL = re.compile(r"^\*\*([^*\n]+):\*\*")


def block_text(line):
    """Remove a small block quote/list prefix, for headings and fences only."""
    text = line.lstrip(" ")
    while text.startswith(">"):
        text = text[1:].lstrip(" ")
    return re.sub(r"^(?:[-+*]|\d+[.)])\s+", "", text)


def comment_line(raw, comment):
    """Mask inline code and comments with their different delimiter precedence."""
    tokens = list(re.finditer(r"<!--|-->|`+", raw))
    next_code, last = {}, {}
    for i in reversed(range(len(tokens))):
        token = tokens[i][0]
        if token.startswith("`"):
            if len(token) in last:
                next_code[i] = last[len(token)]
            last[len(token)] = i
    chunks, cursor, i = [], 0, 0
    while i < len(tokens):
        token = tokens[i]
        if comment:
            if token[0] == "-->":
                comment, cursor = False, token.end()
        elif token[0] == "<!--":
            chunks.append(raw[cursor:token.start()])
            comment, cursor = True, token.end()
        elif i in next_code:
            chunks.extend((raw[cursor:token.start()], "code"))
            i = next_code[i]
            cursor = tokens[i].end()
        i += 1
    if not comment:
        chunks.append(raw[cursor:])
    return "".join(chunks), comment


def markdown_lines(body):
    """Mask comments and literal blocks without changing source line numbers."""
    lines = []
    comment = False
    fence = None
    for raw in body.splitlines():
        text = block_text(raw)
        if fence:
            if (not raw.startswith(("    ", "\t"))
                    and re.fullmatch(re.escape(fence[0]) + "{" + str(fence[1]) + r",}\s*", text)):
                fence = None
            lines.append(("", True))
            continue
        if not comment and (raw.startswith("    ") or raw.startswith("\t")):
            lines.append(("", True))
            continue
        opening = re.match(r"^(`{3,}|~{3,})(.*)$", text)
        if not comment and opening and (opening[1][0] != "`" or "`" not in opening[2]):
            fence = (opening[1][0], len(opening[1]))
            lines.append(("", True))
            continue
        visible, comment = comment_line(raw, comment)
        text = block_text(visible)
        match = re.match(r"^(`{3,}|~{3,})(.*)$", text)
        if match and (match[1][0] != "`" or "`" not in match[2]):
            fence = (match[1][0], len(match[1]))
            lines.append(("", True))
        else:
            lines.append((visible, False))
    return lines


def validate(body, kind):
    """Return at most five fixed diagnostics, with 1-based source lines."""
    if len(body.encode("utf-8")) > MAX_BODY:
        return [{"rule": "input-limit", "line": 1, "hint": HINTS["input-limit"]}]
    problems = set()

    def add(rule, index):
        # Bound work and retained diagnostics even on deliberately repetitive input.
        if len(problems) < 64:
            problems.add((max(1, index + 1), rule))

    lines = markdown_lines(body)
    raw_lines = body.splitlines()
    top = []
    details_depth = 0
    known = set(LABELS["issue"] + LABELS["pr"])
    for i, (line, literal) in enumerate(lines):
        if literal or not line.strip():
            continue
        # Supporting evidence may reuse the opening labels. It cannot supply
        # the visible opening blocks, but still obeys heading/placement rules.
        details_depth += len(re.findall(r"<details\b[^>]*>", line, re.I))
        label = TOP_LABEL.match(line)
        if label and details_depth == 0:
            top.append((i, label[1], label[2] or ""))
        # Tables and inline examples are not label declarations.
        prefix = re.sub(r"^(?:[ \t]*>[ \t]*|[ \t]*(?:[-+*]|\d+[.)])[ \t]+)+", "", line)
        misplaced = ANY_LABEL.match(prefix.lstrip())
        if misplaced and misplaced[1] in known and not label:
            add("label-position", i)
        text = block_text(line)
        if re.match(r"^#{1,6}(?:\s|$)", text):
            add("markdown-heading", i)
        if re.fullmatch(r"(?:=+|-+)[ \t]*", text) and i:
            previous, was_literal = lines[i - 1]
            if (previous.strip() and not was_literal and "|" not in previous
                    and not previous.lstrip().startswith("<")):
                add("markdown-heading", i)
        summary = re.search(r"</summary\s*>", line, re.I)
        if summary and (line[summary.end():].strip()
                        or (i + 1 < len(lines) and (lines[i + 1][0].strip()
                                                   or (lines[i + 1][1] and raw_lines[i + 1].strip())))):
            add("summary-spacing", i)
        details_depth = max(0, details_depth - len(re.findall(r"</details\s*>", line, re.I)))

    first = next((i for i, (line, literal) in enumerate(lines) if line.strip() or literal), 0)
    if not top or top[0][0] != first:
        add("opening-order", first)
    accepted = set()
    for pos, expected in enumerate(LABELS[kind]):
        if pos >= len(top):
            add("opening-order", len(lines) - 1)
            continue
        index, name, value = top[pos]
        if name != expected:
            add("opening-order", index)
            continue
        accepted.add(index)
        if pos and index and (lines[index - 1][0].strip()
                              or (lines[index - 1][1] and raw_lines[index - 1].strip())):
            add("paragraph-separation", index)
        end = top[pos + 1][0] if pos + 1 < len(top) else len(lines)
        values = [(index, value)] if value.strip() else []
        for j in range(index + 1, end):
            line, literal = lines[j]
            if re.match(r"^\s*</?(?:details|summary)\b", line, re.I):
                break
            if name == "Verification" and literal and raw_lines[j].strip():
                add("verification-line", index)
            if line.strip() and not literal:
                values.append((j, line))
        if not values:
            add("empty-value", index)
        elif name == "Plan":
            if (not re.match(r"^1[.)]\s+\S", values[0][1]) or any(
                    not re.match(r"^(?:\d+[.)]\s+\S|\s{2,}\S)", text) for _, text in values)):
                add("plan-numbered", values[0][0])
        elif name == "Done when":
            if any(not re.match(r"^(?:[-+*]\s+\[[ xX]\]\s+\S|\s{2,}\S)", text)
                   for _, text in values) or not re.match(r"^[-+*]\s+\[[ xX]\]\s+\S", values[0][1]):
                add("done-checklist", values[0][0])
        elif name == "Verification" and len(values) != 1:
            add("verification-line", index)
    for index, name, _ in top:
        if name in LABELS[kind] and index not in accepted:
            add("label-position", index)
    return [{"rule": rule, "line": line, "hint": HINTS[rule]}
            for line, rule in sorted(problems)[:MAX_DIAGNOSTICS]]


def regular_text(path, limit, *, follow=False):
    """Never follow a final symlink or wait for a FIFO/device used as a body."""
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | (0 if follow else os.O_NOFOLLOW))
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise ValueError("not a bounded regular file")
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError("input too large")
        return data.decode("utf-8")


def utc_now():
    return dt.datetime.now(dt.timezone.utc)


def timestamp(value):
    return value.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def parse_end(value):
    end = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if end.tzinfo is None or end.utcoffset() != dt.timedelta(0):
        raise ValueError("UTC timestamp required")
    return end


def target_key(value):
    """Accept host-qualified repository identifiers and credential-free HTTPS URLs."""
    if not isinstance(value, str) or len(value) > 4096:
        return None
    if "://" in value:
        try:
            url = urllib.parse.urlsplit(value)
            port = url.port
        except ValueError:
            return None
        if url.scheme != "https" or url.username or url.password or url.query or url.fragment:
            return None
        host = url.hostname or ""
        if port:
            host += ":" + str(port)
        parts = [host] + url.path.strip("/").split("/")
    else:
        parts = value.split("/")
    if len(parts) != 3:
        return None
    parts[-1] = re.sub(r"\.git$", "", parts[-1])
    if (not re.fullmatch(r"[A-Za-z0-9.-]+(?::[0-9]+)?", parts[0])
            or any(not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", p) or p in (".", "..")
                   for p in parts[1:])):
        return None
    return "/".join(parts).lower()


def load_config(path):
    if not path:
        return None
    # A deployed Nix configuration may itself be a link to a store file.
    config = json.loads(regular_text(path, MAX_CONFIG, follow=True))
    if not isinstance(config, dict):
        raise ValueError("bad configuration")
    if type(config.get("schema")) is not int or config["schema"] != 1 or config.get("mode") not in ("off", "observe"):
        raise ValueError("bad mode or schema")
    host = config["forgejo_host"]  # Required: no guessed production host.
    if not isinstance(host, str) or not re.fullmatch(r"[A-Za-z0-9.-]+(?::[0-9]+)?", host):
        raise ValueError("bad host")
    config["end"] = (None if config["mode"] == "off" and config["end_at"] is None
                     else parse_end(config["end_at"]))
    if not isinstance(config["state_dir"], str) or not os.path.isabs(config["state_dir"]):
        raise ValueError("absolute state directory required")
    repositories = config["repositories"]
    if not isinstance(repositories, dict):
        raise ValueError("bad repositories")
    normalized = {}
    for key, kinds in repositories.items():
        target = target_key(key)
        if (not target or target != key.lower() or not isinstance(kinds, dict)
                or any(k not in LABELS or type(v) is not bool for k, v in kinds.items())):
            raise ValueError("bad repository entry")
        normalized[target] = kinds
    config["repositories"] = normalized
    return config


def shell_words(command):
    """Tiny quote-aware lexer. Return words plus uncertainty, never evaluate."""
    command = command.strip()
    words, current = [], []
    quote = None
    started = False
    uncertain = False
    i = 0
    while i < len(command):
        char = command[i]
        if quote == "'":
            if char == "'":
                quote = None
            else:
                current.append(char)
        elif char == "\\":
            i += 1
            if i == len(command):
                uncertain = True
                break
            escaped = command[i]
            if escaped != "\n":
                if quote == '"' and escaped not in '$`"\\':
                    current.append("\\")
                current.append(escaped)
            started = True
        elif quote == '"':
            if char == '"':
                quote = None
            else:
                uncertain |= char in "$`"
                current.append(char)
        elif char in "'\"":
            quote, started = char, True
        elif char.isspace():
            # A trailing newline is harmless; embedded command separators are not.
            if char == "\n":
                uncertain = True
            if started:
                words.append("".join(current))
                current, started = [], False
        else:
            uncertain |= char in "$`|&;<>()*?[]{}~#"
            current.append(char)
            started = True
        i += 1
    if started:
        words.append("".join(current))
    return words, uncertain or quote is not None


def item_url(value, kind):
    try:
        url = urllib.parse.urlsplit(value)
    except ValueError:
        return None
    match = re.fullmatch(r"/([^/]+)/([^/]+)/(issues|pull|pulls)/(\d+)/?", url.path)
    if (url.scheme != "https" or not match or url.username or url.password
            or url.query or url.fragment
            or (match[3] == "issues") != (kind == "issue")):
        return None
    return target_key("https://" + url.netloc + "/" + match[1] + "/" + match[2])


VALUE_FLAGS = {
    "--assignee", "-a", "--add-assignee", "--remove-assignee", "--label", "-l",
    "--add-label", "--remove-label", "--milestone", "-m", "--project", "-p",
    "--add-project", "--remove-project", "--title", "-t", "--base", "-B", "--head", "-H",
    "--reviewer", "-r", "--add-reviewer", "--remove-reviewer", "--repo", "-R",
    "--body", "-b", "--body-file", "-F", "--template", "-T", "--recover",
}
BOOL_FLAGS = {"--draft", "-d", "--web", "-w", "--editor", "-e", "--fill", "--fill-first",
              "--fill-verbose", "--help", "-h", "--remove-milestone"}


def gh_candidate(command, cwd):
    words, uncertain = shell_words(command)
    if len(words) < 3 or words[0] != "gh" or words[1] not in LABELS or words[2] not in ("create", "edit"):
        return None
    kind, action = words[1:3]
    options, positionals, repo_values = {}, [], []
    i = 3
    while i < len(words):
        word = words[i]
        flag, sep, value = word.partition("=")
        if not word.startswith("--") and len(word) > 2 and word[:2] in VALUE_FLAGS:
            flag, sep, value = word[:2], "=", word[2:]
        if flag in VALUE_FLAGS:
            if not sep:
                i += 1
                if i >= len(words):
                    if flag in ("--repo", "-R"):
                        repo_values.append(None)
                    uncertain = True
                    break
                value = words[i]
            options[flag] = value
            if flag in ("--repo", "-R"):
                repo_values.append(value)
        elif word in BOOL_FLAGS:
            options[word] = True
        elif word.startswith("-"):
            uncertain = True
        else:
            positionals.append(word)
        i += 1
    if "--help" in options or "-h" in options:
        return None
    targets = [target_key(value) for value in repo_values]
    for value in positionals:
        target = item_url(value, kind)
        if target:
            targets.append(target)
        elif "://" in value:
            targets.append(None)
            uncertain = True
        elif action != "edit" or not value.isdigit():
            uncertain = True
    if len(positionals) > (1 if action == "edit" else 0):
        uncertain = True
    target = targets[0] if targets else None
    if any(t != target or t is None for t in targets):
        target = None
    if target is None:
        return {"route": "gh", "target": None, "kind": kind,
                "source": "unsupported-target", "body": None}
    bodies = [("file" if k in ("--body-file", "-F") else "literal", options[k])
              for k in ("--body", "-b", "--body-file", "-F") if k in options]
    generated = any(k in options for k in ("--web", "-w", "--editor", "-e", "--fill",
                                           "--fill-first", "--fill-verbose", "--template", "-T", "--recover"))
    if uncertain or generated or len(bodies) > 1 or (not bodies and action == "create"):
        source, body = "unsupported", None
    elif not bodies:
        # An edit with no changed fields invokes an interactive editor.
        metadata = VALUE_FLAGS - {"--repo", "-R", "--body", "-b", "--body-file", "-F", "--template", "-T", "--recover"}
        source = "metadata" if metadata.intersection(options) or "--remove-milestone" in options else "unsupported"
        body = None
    else:
        source, body = bodies[0]
    return {"route": "gh", "target": target, "kind": kind, "source": source,
            "body": body, "cwd": cwd}


def classify(payload, config):
    if not isinstance(payload, dict):
        raise ValueError("bad payload")
    name = payload.get("tool_name")
    # Anchored aliases only. Never accept an arbitrary tool merely by its suffix.
    match = re.fullmatch(
        r"(?:functions\.)?(?:mcp__forgejo__|mcp_forgejo_)(create_issue|update_issue|create_pull_request|update_pull_request)",
        name if isinstance(name, str) else "",
    )
    if match:
        args = payload.get("tool_input")
        if not isinstance(args, dict):
            raise ValueError("bad arguments")
        owner, repo = args.get("owner"), args.get("repo")
        target = target_key(config["forgejo_host"] + "/" + owner + "/" + repo) if isinstance(owner, str) and isinstance(repo, str) else None
        kind = "pr" if "pull_request" in match[1] else "issue"
        source = "metadata" if match[1].startswith("update_") and "body" not in args else "literal"
        return {"route": "forgejo", "target": target, "kind": kind,
                "source": source, "body": args.get("body", "")}
    if name in ("Bash", "exec_command", "functions.exec_command"):
        args = payload.get("tool_input")
        if not isinstance(args, dict):
            raise ValueError("bad arguments")
        command = args.get("command" if name == "Bash" else "cmd")
        if not isinstance(command, str):
            return None
        cwd = args.get("workdir", payload.get("cwd"))
        if cwd is not None and (not isinstance(cwd, str) or not os.path.isabs(cwd)):
            raise ValueError("bad working directory")
        return gh_candidate(command, cwd)
    return None


@contextlib.contextmanager
def locked_state(path, create=False):
    """Use directory-relative descriptors, reject symlinks, share append/report lock."""
    if create:
        os.makedirs(path, mode=0o700, exist_ok=True)
    directory = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fchmod(directory, 0o700)
        lock = os.open("events.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK,
                       0o600, dir_fd=directory)
        try:
            if not stat.S_ISREG(os.fstat(lock).st_mode):
                raise ValueError("not a regular lock")
            os.fchmod(lock, 0o600)
            deadline = time.monotonic() + 1
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("state lock busy")
                    time.sleep(0.01)
            yield directory
        finally:
            os.close(lock)
    finally:
        os.close(directory)


def log_name(index):
    return "events.jsonl" + ("." + str(index) if index else "")


def append_event(config, event):
    encoded = (json.dumps(event, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")
    if len(encoded) > LOG_BYTES:
        raise ValueError("event too large")
    with locked_state(config["state_dir"], create=True) as directory:
        if utc_now() >= config["end"]:
            return
        flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK
        fd = os.open(log_name(0), flags, 0o600, dir_fd=directory)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                raise ValueError("not a regular log")
            os.fchmod(fd, 0o600)
            if info.st_size + len(encoded) > LOG_BYTES:
                os.close(fd)
                fd = None
                for index in range(LOG_FILES - 1, 0, -1):
                    try:
                        os.rename(log_name(index - 1), log_name(index), src_dir_fd=directory, dst_dir_fd=directory)
                    except FileNotFoundError:
                        pass
                fd = os.open(log_name(0), flags | os.O_EXCL, 0o600, dir_fd=directory)
            os.write(fd, encoded)
        finally:
            if fd is not None:
                os.close(fd)


def notice(message):
    try:
        print("description-format: " + message, file=sys.stderr)
    except (OSError, ValueError):
        pass


def warning():
    notice("observation unavailable; allowing tool call.")


def managed_observer_available():
    return os.access("/etc/codex/hooks/agent-description-format-observe", os.X_OK)


def hook(config_path, stream, delivery="direct"):
    """No hook failure, including configuration/classification/logging, may deny."""
    start = time.monotonic()
    try:
        # Consume an ordinary event before any quiet early return, but never
        # drain an unbounded input. Real stdin is read with a byte bound.
        raw = getattr(stream, "buffer", stream).read(MAX_INPUT + 1)
        config = load_config(config_path)
        if config is None or config["mode"] == "off" or utc_now() >= config["end"]:
            return 0
        if delivery == "codex-user" and managed_observer_available():
            return 0
        if delivery not in DELIVERIES:
            raise ValueError("bad delivery")
    except FileNotFoundError:
        return 0
    except Exception:
        warning()
        return 0
    event = {"schema": 1, "version": VERSION, "timestamp": timestamp(utc_now()),
             "route": "unmatched", "outcome": "skip", "delivery": delivery}
    try:
        if len(raw.encode("utf-8") if isinstance(raw, str) else raw) > MAX_INPUT:
            raise ValueError("input too large")
        candidate = classify(json.loads(raw), config)
        if candidate:
            event["route"] = candidate["route"]
            target, kind = candidate["target"], candidate["kind"]
            kinds = config["repositories"].get(target)
            if candidate["source"] == "unsupported-target":
                event.update(outcome="unsupported", kind=kind,
                             rules=[{"rule": "unsupported-target", "line": 1}])
                notice(HINTS["unsupported-target"])
            elif kinds is not None:
                event.update(target=target, kind=kind)
                if kinds.get(kind, False) and candidate["source"] != "metadata":
                    source, body = candidate["source"], candidate["body"]
                    if source == "file":
                        try:
                            if body == "-":
                                raise ValueError("stdin unsupported")
                            body = regular_text(os.path.join(candidate["cwd"] or os.getcwd(), body), MAX_BODY)
                        except (OSError, ValueError, UnicodeError):
                            source = "unsupported"
                    if source == "unsupported" or not isinstance(body, str):
                        diagnostics = [{"rule": "unsupported-body", "line": 1, "hint": HINTS["unsupported-body"]}]
                        event["outcome"] = "unsupported"
                    else:
                        diagnostics = validate(body, kind)
                        event["outcome"] = "invalid" if diagnostics else "valid"
                    event["rules"] = [{"rule": d["rule"], "line": d["line"]} for d in diagnostics]
                    for diagnostic in diagnostics:
                        notice(diagnostic["hint"])
    except Exception:
        event["outcome"] = "error"
        warning()
    event["elapsed_ms"] = max(0, round((time.monotonic() - start) * 1000))
    try:
        append_event(config, event)
    except Exception:
        warning()
    return 0


def report(path):
    """Counts are delivered attempts, never successful API writes."""
    result = {"schema": 1, "version": VERSION, "counts_attempts_not_api_success": True,
              "retention": {"files": LOG_FILES, "bytes_per_file": LOG_BYTES,
                            "oldest": None, "newest": None},
              "attempts": 0, "candidates": 0, "malformed_records": 0,
              "outcomes": {}, "routes": {}, "kinds": {}, "rules": {}, "days": {},
              "deliveries": {}, "delivery_outcomes": {}, "elapsed_ms_total": 0}
    counters = {name: collections.Counter() for name in ("outcomes", "routes", "kinds", "rules", "days", "deliveries")}
    delivery_outcomes = collections.defaultdict(collections.Counter)
    try:
        with locked_state(path) as directory:
            for index in reversed(range(LOG_FILES)):
                try:
                    fd = os.open(log_name(index), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
                except FileNotFoundError:
                    continue
                with os.fdopen(fd, "rb") as stream:
                    info = os.fstat(stream.fileno())
                    if not stat.S_ISREG(info.st_mode) or info.st_size > LOG_BYTES:
                        raise ValueError("unbounded log")
                    for raw in stream:
                        try:
                            event = json.loads(raw)
                            if event["schema"] != 1 or event["version"] != VERSION:
                                raise ValueError("unknown schema")
                            route, outcome = event["route"], event["outcome"]
                            if route not in ("unmatched", "gh", "forgejo") or outcome not in ("skip", "valid", "invalid", "unsupported", "error"):
                                raise ValueError("unknown event")
                            # Pre-tagging events used the unqualified direct API.
                            delivery = event.get("delivery", "direct")
                            if delivery not in DELIVERIES:
                                raise ValueError("unknown delivery")
                            stamp = timestamp(parse_end(event["timestamp"]))
                            elapsed = event["elapsed_ms"]
                            if type(elapsed) is not int or not 0 <= elapsed <= 86400000:
                                raise ValueError("bad duration")
                            rules = event.get("rules", [])
                            if not isinstance(rules, list) or len(rules) > MAX_DIAGNOSTICS or any(
                                    d.get("rule") not in HINTS or type(d.get("line")) is not int or d["line"] < 1 for d in rules):
                                raise ValueError("bad rules")
                            if "kind" in event and event["kind"] not in LABELS:
                                raise ValueError("unknown kind")
                        except (ValueError, TypeError, KeyError, AttributeError):
                            result["malformed_records"] += 1
                            continue
                        result["attempts"] += 1
                        result["candidates"] += "target" in event
                        counters["routes"][route] += 1
                        counters["outcomes"][outcome] += 1
                        counters["deliveries"][delivery] += 1
                        delivery_outcomes[delivery][outcome] += 1
                        counters["days"][stamp[:10]] += 1
                        if event.get("kind") in LABELS:
                            counters["kinds"][event["kind"]] += 1
                        for rule in rules:
                            counters["rules"][rule["rule"]] += 1
                        result["elapsed_ms_total"] += elapsed
                        window = result["retention"]
                        window["oldest"] = min(window["oldest"] or stamp, stamp)
                        window["newest"] = max(window["newest"] or stamp, stamp)
    except FileNotFoundError:
        pass
    for name, counter in counters.items():
        result[name] = dict(sorted(counter.items()))
    result["delivery_outcomes"] = {name: dict(sorted(counts.items()))
                                   for name, counts in sorted(delivery_outcomes.items())}
    return result


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    # Hook argument/config errors are also fail-open. Avoid argparse's exit(2)
    # and usage output, which could echo arbitrary hook arguments.
    if argv and argv[0] == "hook":
        options = {}
        arguments = argv[1:]
        valid = len(arguments) % 2 == 0
        for flag, value in zip(arguments[::2], arguments[1::2]):
            if flag not in ("--config", "--delivery") or flag in options:
                valid = False
            options[flag] = value
        if valid and options.get("--delivery", "direct") in DELIVERIES:
            return hook(options.get("--config"), sys.stdin, options.get("--delivery", "direct"))
        warning()
        return hook(None, sys.stdin)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validator = commands.add_parser("validate")
    validator.add_argument("--kind", choices=tuple(LABELS), required=True)
    observer = commands.add_parser("hook")
    observer.add_argument("--config")
    observer.add_argument("--delivery", choices=DELIVERIES, default="direct")
    config_validator = commands.add_parser("validate-config")
    config_validator.add_argument("--config", required=True)
    reporter = commands.add_parser("report")
    reporter.add_argument("--state-dir", required=True)
    args = parser.parse_args(argv)
    if args.command == "validate-config":
        try:
            if load_config(args.config) is None:
                raise ValueError("missing configuration")
            return 0
        except Exception:
            notice("invalid or missing configuration.")
            return 1
    if args.command == "report":
        try:
            print(json.dumps(report(args.state_dir), sort_keys=True))
            return 0
        except Exception:
            print("description-format: report unavailable.", file=sys.stderr)
            return 1
    try:
        body = sys.stdin.read(MAX_BODY + 1)
        diagnostics = validate(body, args.kind)
    except Exception:
        diagnostics = [{"rule": "input-limit", "line": 1, "hint": HINTS["input-limit"]}]
    print(json.dumps({"valid": not diagnostics, "diagnostics": diagnostics}, sort_keys=True))
    return int(bool(diagnostics))


if __name__ == "__main__":
    sys.exit(main())
