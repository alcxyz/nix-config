"""Break a T3 thread's time down by kind of work, as JSON.

Reads T3's state database read-only. Every run's wall time is split across
the items in it: a tool call owns its own run time plus the model time spent
deciding on and writing it (a large edit is mostly generation), and the time
after a run's last tool call is spent writing the reply. Time between runs is
either the user's (the next run starts with their message) or a wait on
background work (a notification starts it), classified by what woke it.

Command text is read here to classify it and never printed beyond a short
label, and each user message only as its first line, so the output carries
no file contents or long prose.

Exit codes: 2 no database or thread found, 3 T3's schema changed, 64 usage.
"""

import argparse
import bisect
import datetime
import json
import os
import re
import sqlite3
import sys

PROG = "t3-thread-time"
LABEL_MAX = 80
# A waiting run is live too: it waits for the user's input.
LIVE_RUN = ("preparing", "starting", "running", "waiting")
LIVE_ITEM = ("pending", "running", "waiting")
# Calls issued together start within this many seconds of each other.
BATCH_SECONDS = 1.0
# Items T3 records about a call rather than calls the agent makes.
RECORDS = ("user_input_request", "approval_request")
REQUEST_MAX = 160
MAX_REQUESTS = 200

# Display order. "idle" is time between runs longer than --idle-minutes,
# kept out of the user's share.
CATEGORIES = [
    "discussion",
    "tracking",
    "explore",
    "research",
    "coding",
    "test",
    "build",
    "git",
    "review",
    "ci",
    "deploy",
    "verify",
    "delegation",
    "waiting",
    "other",
]
# Time before a run that is not the agent's: the user's turnaround, and idle.
HUMAN = ["user", "idle"]

# Shell rules, tried in order on a command with its heredoc bodies removed,
# after the file writes that make it coding. The first match wins, so specific
# intents (deploy, review) come before generic ones (git, explore).
SHELL_RULES = [
    ("deploy", r"^\s*(sudo\s+)?deploy\b|[;&|(]\s*(sudo\s+)?deploy\b|nixos-rebuild|home-manager switch|kubectl\b[^|;&\n]*\b(apply|rollout)\b|flux reconcile|argocd app sync"),
    ("review", r"\bpr-review\b|codex review|/code-review"),
    ("ci", r"/actions/(runs|jobs|tasks)|\bgh run\b|\bgh pr checks\b|workflow_run|ci status"),
    ("tracking", r"\btea (issues?|pr|pulls?|milestones?|labels?|comment|api)\b|\bgh (issue|pr|api)\b|/issues\b|/pulls\b"),
    ("test", r"\b(vitest|jest|playwright|pytest|go test|cargo test|bats)\b|\bpnpm( run)? (test|e2e|lint|typecheck|check)\b|\bnpm( run)? (test|lint)\b|\b(just|make) (test|check|lint|input)\b|nix flake check|\btsc\b|\beslint\b|\bbiome\b|\bshellcheck\b|\bstatix\b|\bdeadnix\b|nix build [^|;&]*checks\."),
    ("build", r"\b(pnpm|npm|yarn)( run)? build\b|\bvite build\b|\bnix build\b|\bgo build\b|\bcargo build\b|\b(docker|podman|buildah) build\b|\b(pnpm|npm|yarn) (install|i|add)\b|\bcorepack\b.*\binstall\b|\bnix flake (update|lock)\b|\bmake\b"),
    ("verify", r"\b(pnpm|npm|yarn)( run)? (dev|preview|start)\b|\bcurl\b|\bnode -e\b|\bchromium\b|\bscreenshot\b|kubectl\b[^|;&\n]*\b(port-forward|logs|exec)\b"),
    ("git", r"\bgit (commit|push|rebase|merge|checkout|switch|worktree|fetch|pull|stash|cherry-pick|reset|branch|add|restore|tag|am)\b"),
    ("waiting", r"^\s*(sleep|until|while)\b|\bagent-job\b|\bwait\b"),
]
# Writes that make a command coding: shell writes in the command itself, and
# script writes anywhere, since the edit script is often a heredoc body fed to
# python or node. Writes to temporary files, such as an issue body, do not
# count, and neither do words in a commit message.
WRITE_RE = re.compile(
    r"\bcat\s*(<<-?\s*['\"]?\w+['\"]?\s*)?>{1,2}\s*(?![\"']?(/tmp/|/dev/|\$))\S|\btee\s+(-a\s+)?(?![\"']?(/tmp/|/dev/|\$|-))\S|"
    r"\bsed -i\b|\bperl -pi\b|\bapply_patch\b|"
    r"\bpatch -p\d|\bgofmt -w\b|\bprettier --write\b|\bnixfmt\b|\balejandra\b"
)
SCRIPT_WRITE_RE = re.compile(
    r"\.write_text\(|\bopen\([^)]*['\"][wa]['\"]|writeFileSync"
)
EXPLORE_RE = re.compile(
    r"^\s*(cd\s+\S+\s*(&&|;)\s*)?(rg|fd|grep|find|cat|sed -n|head|tail|ls|tree|wc|jq|less|file|stat|"
    r"git (log|show|diff|status|blame|grep|ls-files|rev-parse|branch --show)|sqlite3|nix (eval|search|path-info|why-depends)|"
    r"readlink|realpath|which|type|command -v|systemctl (status|show|list)|journalctl|ps|pgrep|date|echo)\b"
)
HEREDOC_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1[^\n]*\n(.*?)\n\s*\2\s*(\n|$)", re.S)

# Tool names (Claude and Codex dynamic tools, MCP tools) by category.
TOOL_RULES = [
    ("coding", r"^(Edit|MultiEdit|Write|NotebookEdit|apply_patch)$"),
    ("explore", r"^(Read|Grep|Glob|LS|LSP|view_image)$|^mcp__forgejo__(get_file_content|get_repo_tree|list_repo_contents|list_repo_commits|list_branches)$"),
    ("research", r"^(WebSearch|WebFetch)$|mcp__claude_ai_Claude_Docs__|Google_Drive"),
    ("ci", r"^mcp__forgejo__.*(action|workflow)"),
    ("review", r"^mcp__forgejo__.*(review|diff)|^mcp__forgejo__list_pull_request_files$"),
    ("tracking", r"^mcp__forgejo__|pull_request|link_pull_request|^mcp__t3[-_]code__(watch|unwatch)_pull_request$"),
    ("delegation", r"^(Agent|Task|SendMessage|TaskOutput|TaskStop|Workflow)$|delegate_task|task_status|task_cancel|t3_thread_|create_threads|orchestrator_capabilities"),
    ("verify", r"preview_|device_|Claude_Browser|claude-in-chrome|computer"),
    ("waiting", r"^(Monitor|ScheduleWakeup|CronCreate|BashOutput|KillShell)$"),
    ("discussion", r"^(AskUserQuestion|html_render|html_preview)$|html_render|html_preview|request_secret"),
]


def fail(code, message):
    print(f"{PROG}: {message}", file=sys.stderr)
    sys.exit(code)


def parse_time(value):
    if not value:
        return None
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).isoformat().replace("+00:00", "Z")


PREFIX_RE = re.compile(r"^(cd\s+\S+\s*(&&|;)\s*|timeout\s+\S+\s+|(env\s+)?[A-Z_][A-Z0-9_]*=\S*\s+)+")


def label(text, limit=LABEL_MAX):
    first = next((line.strip() for line in (text or "").splitlines() if line.strip()), "")
    first = PREFIX_RE.sub("", first)
    return first[: limit - 1] + "…" if len(first) > limit else first


MESSAGE_RE = re.compile(r"""(\s(?:-[A-Za-z]*m|--message|--title|--body))(?:=|\s*)("(?:[^"\\]|\\.)*"|'[^']*')""")


def strip_heredocs(text):
    """Leave out text that is not shell: heredoc bodies and quoted messages."""
    text = HEREDOC_RE.sub(lambda m: m.group(0).split("\n", 1)[0] + "\n", text)
    return MESSAGE_RE.sub(r"\1 MSG", text)


def shell_command(kind, payload):
    """The shell text of a command item, or of a client's shell tool call."""
    if kind == "command_execution":
        return payload.get("input")
    if kind == "dynamic_tool" and is_shell_tool(payload.get("toolName")):
        tool_input = payload.get("input")
        return tool_input.get("command") if isinstance(tool_input, dict) else None
    return None


def is_question(kind, payload):
    """A question that stops the agent until the user answers. Claude's
    AskUserQuestion call and T3's question item cover the same wait; a question
    answered by a later message (responseMode "message") stops nothing."""
    if payload.get("responseMode") == "message":
        return False
    return kind in ("user_input_request", "approval_request") or (
        kind == "dynamic_tool" and payload.get("toolName") == "AskUserQuestion"
    )


def is_shell_tool(name):
    name = name or ""
    return name in ("Bash", "shell", "exec_command") or name.endswith("__shell")


def classify_command(text):
    text = text or ""
    shell = strip_heredocs(text)
    # The model time before an edit is spent writing it, so an edit makes
    # the whole command coding, even when it then commits or starts a review.
    if WRITE_RE.search(shell) or SCRIPT_WRITE_RE.search(MESSAGE_RE.sub(r"\1 MSG", text)):
        return "coding"
    for category, rule in SHELL_RULES:
        if re.search(rule, shell, re.I | re.M):
            return category
    if EXPLORE_RE.search(shell):
        return "explore"
    return "other"


def classify_tool(name, payload):
    name = name or ""
    if is_shell_tool(name):
        return classify_command(shell_command("dynamic_tool", payload))
    for category, rule in TOOL_RULES:
        if re.search(rule, name):
            return category
    return "other"


def item_category(kind, payload):
    if kind == "command_execution":
        return classify_command(payload.get("input"))
    if kind == "dynamic_tool":
        return classify_tool(payload.get("toolName"), payload)
    if kind == "file_change":
        return "coding"
    if kind == "web_search":
        return "research"
    if kind == "subagent":
        return "delegation"
    if kind in ("user_input_request", "approval_request"):
        return "discussion"
    return None


def wake_category(summary, source=None):
    """Classify the background work whose notification started a run."""
    text = summary or ""
    if isinstance(source, dict) and (source.get("kind") in ("delegated_task", "subagent") or source.get("work") == "subagent"):
        return "delegation"
    if text.startswith("Subagent"):
        return "delegation"
    for category, rule in SHELL_RULES[:3]:
        if re.search(rule, text, re.I):
            return category
    if re.search(r"\bdeploy|roll ?out|switch\b", text, re.I):
        return "deploy"
    if re.search(r"\breview\b", text, re.I):
        return "review"
    if re.search(r"\bCI\b|checks?\b|pipeline|workflow", text):
        return "ci"
    if re.search(r"\btests?\b|e2e|playwright", text, re.I):
        return "test"
    if re.search(r"\bbuild\b", text, re.I):
        return "build"
    if re.search(r"subagent|task", text, re.I):
        return "delegation"
    return "waiting"


REVIEW_RUN_RE = re.compile(
    r"\bpr-review run\s+(?:-\S+\s+)*(?:[\"']?https?://\S+?/([^/\s]+)/pulls?/(\d+)|(\d+))\b"
)
CD_RE = re.compile(r"\bcd\s+[\"']?(?:~|\$HOME|/home/[^/\s]+)/src/(?:\.worktrees/)?[^/\s]+/([^/\s\"';&]+)")


def review_targets(command, repo=None):
    """Name each `pr-review run` in a command as repo#N, from its URL, the
    command's last cd before it, or else REPO (the thread's last cd, since a
    shell's directory persists between calls).

    Heredoc bodies are text, not commands, so they are left out."""
    shell = strip_heredocs(command or "")
    targets = []
    for match in REVIEW_RUN_RE.finditer(shell):
        if match.group(1):
            targets.append(f"{match.group(1)}#{match.group(2)}")
            continue
        repos = CD_RE.findall(shell[: match.start()])
        name = repos[-1] if repos else repo
        targets.append(f"{name}#{match.group(3)}" if name else f"#{match.group(3)}")
    return targets


SUBSHELL_RE = re.compile(r"\$?\([^()]*\)")


def last_repo(command, repo=None):
    """The repository the shell is in after COMMAND; a cd inside a subshell
    does not move it."""
    shell = strip_heredocs(command or "")
    while SUBSHELL_RE.search(shell):
        shell = SUBSHELL_RE.sub(" ", shell)
    repos = CD_RE.findall(shell)
    return repos[-1] if repos else repo


# Bin sizes for the timeline, in minutes; the smallest that gives at most
# MAX_BINS bins is used.
BIN_MINUTES = [5, 10, 15, 30, 60, 120, 240, 480, 1440]
MAX_BINS = 160


def bin_timeline(segments, span_start, span_end):
    span = max(span_end - span_start, 1)
    size = next((m * 60 for m in BIN_MINUTES if span / (m * 60) <= MAX_BINS), BIN_MINUTES[-1] * 60)
    bins = {}
    for t0, t1, cat, _ in segments:
        while t0 < t1:
            index = int((t0 - span_start) // size)
            edge = min(t1, span_start + (index + 1) * size)
            row = bins.setdefault(index, {})
            row[cat] = row.get(cat, 0) + edge - t0
            t0 = edge
    return size // 60, [
        {"start": iso(span_start + i * size), "seconds": {c: round(v) for c, v in sorted(row.items()) if v >= 1}}
        for i, row in sorted(bins.items())
    ]


def merge_intervals(intervals):
    merged = []
    for t0, t1 in sorted(intervals):
        if merged and t0 <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], t1)
        else:
            merged.append([t0, t1])
    return merged


def carve(segments, q0, q1, cat):
    """Relabel the parts of SEGMENTS inside [q0, q1] as CAT."""
    out = []
    for t0, t1, c, owner in segments:
        a, b = max(t0, q0), min(t1, q1)
        if a >= b:
            out.append((t0, t1, c, owner))
            continue
        if t0 < a:
            out.append((t0, a, c, owner))
        out.append((a, b, cat, owner))
        if b < t1:
            out.append((b, t1, c, owner))
    return out


def open_db(paths, thread):
    """Open the first database holding the thread, like t3-state-db.sh: one
    that cannot be queried is skipped, and fails the run (exit 3) only when no
    other database holds the thread."""
    unreadable = []
    for path in paths:
        if not os.access(path, os.R_OK):
            continue
        try:
            db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
            found = db.execute(
                "SELECT count(*) FROM orchestration_v2_projection_threads WHERE thread_id = ?", (thread,)
            ).fetchone()[0]
        except sqlite3.Error:
            unreadable.append(path)
            continue
        if found:
            return path, db
        db.close()
    if unreadable:
        fail(3, f"could not query {' '.join(unreadable)}; T3's schema may have changed")
    fail(2, f"no readable T3 state database holding thread {thread} among: {' '.join(paths)}")


def run_has_start_key(payload_json):
    try:
        return "startedAt" in json.loads(payload_json)
    except (TypeError, ValueError):
        fail(3, "a run payload is not a JSON object; T3's schema may have changed")


def load(db, thread):
    try:
        # Every item must carry the times the split relies on; without them
        # time would silently move to the reply.
        drift = db.execute(
            "SELECT count(*) FROM orchestration_v2_projection_turn_items WHERE thread_id = ?"
            " AND (NOT json_valid(payload_json) OR json_type(payload_json, '$.startedAt') IS NULL"
            " OR json_type(payload_json, '$.completedAt') IS NULL"
            " OR json_type(payload_json, '$.startedAt') = 'null'"
            " OR (status NOT IN ('pending', 'running', 'waiting')"
            " AND json_type(payload_json, '$.completedAt') = 'null'))",
            (thread,),
        ).fetchone()[0]
        title, created = db.execute(
            "SELECT title, created_at FROM orchestration_v2_projection_threads WHERE thread_id = ?", (thread,)
        ).fetchone()
        runs = db.execute(
            "SELECT run_id, ordinal, status, requested_at, completed_at, payload_json"
            " FROM orchestration_v2_projection_runs WHERE thread_id = ? ORDER BY ordinal",
            (thread,),
        ).fetchall()
        items = db.execute(
            "SELECT run_id, ordinal, type, status, payload_json"
            " FROM orchestration_v2_projection_turn_items WHERE thread_id = ? ORDER BY ordinal",
            (thread,),
        ).fetchall()
    except sqlite3.Error as err:
        fail(3, f"query failed ({err}); T3's schema may have changed")
    if drift:
        fail(3, f"{drift} turn items lack startedAt or completedAt; T3's schema has changed")
    # A run that never started (withdrawn, or failed while preparing) stores
    # startedAt as null; a run without the key at all means drift.
    missing = sum(1 for row in runs if not run_has_start_key(row[5]))
    if missing:
        fail(3, f"{missing} runs lack a startedAt field; T3's schema has changed")
    return title, created, runs, items


def pseudo_runs(loose):
    """Runs for items stored without one: threads from before T3's run
    projection, and native subagent threads. A user message that starts a
    turn (not a steer or a queued message, which arrive while a turn runs) or
    a notification starts a run, which lasts until its last item ends or the
    next run starts. Without T3's run status nothing shows whether such a run
    is still going, so these runs count as finished: work still running in
    one counts only up to its start, which can understate a live thread. A
    background item that completes late still extends its run, and the time
    after the reply then counts as discussion."""
    loose = sorted(loose, key=lambda item: (parse_time(item[3].get("startedAt")) or 0, item[0]))
    groups = []
    for item in loose:
        starts_turn = item[1] == "notification" or (
            item[1] == "user_message"
            and item[3].get("inputIntent") not in ("promoted_queued_to_steer", "steer", "queued_turn")
        )
        if not groups or starts_turn:
            groups.append([])
        groups[-1].append(item)
    rows, members = [], {}
    for number, group in enumerate(groups):
        start = min(parse_time(item[3].get("startedAt")) for item in group)
        end = max(parse_time(item[3].get("completedAt")) or parse_time(item[3].get("startedAt")) for item in group)
        if number + 1 < len(groups):
            end = min(end, min(parse_time(item[3].get("startedAt")) for item in groups[number + 1]))
        run_id = f"pseudo:{number}"
        members[run_id] = group
        rows.append((run_id, -1, "completed", iso(start), iso(end), json.dumps({"startedAt": iso(start)})))
    return rows, members


def analyse(thread, title, runs, items, idle_minutes, now):
    # Agent time inside runs, background waits between them, and the user's.
    totals = {c: 0.0 for c in CATEGORIES}
    waits = {c: 0.0 for c in CATEGORIES}
    human = {c: 0.0 for c in HUMAN}
    counts = {c: 0 for c in CATEGORIES}
    failures = {c: 0 for c in CATEGORIES}
    timeline = []
    longest = []
    by_run = {}
    for run_id, ordinal, kind, status, payload_json in items:
        try:
            payload = json.loads(payload_json)
        except ValueError:
            fail(3, "a turn item payload is not JSON; T3's schema may have changed")
        by_run.setdefault(run_id, []).append((ordinal, kind, status, payload))
    extra_runs, extra_items = pseudo_runs(by_run.pop(None, []))
    runs = list(runs) + extra_runs
    by_run.update(extra_items)

    stats = {
        "runs": len(runs),
        "userMessages": 0,
        "steers": 0,
        "wakeups": 0,
        "compactions": 0,
        "interruptedRuns": 0,
        "failedRuns": 0,
    }
    checks = {}
    reviews = {}
    requests = []
    background = None
    repo = None
    prev_end = None
    def run_start(row):
        # Only a run that started has a start; a queued or withdrawn one does
        # not, and its request time is not a start.
        return parse_time(json.loads(row[5]).get("startedAt"))

    # T3 can start queued runs out of request order, so take runs in the order
    # they started; those that never started keep their place for messages.
    runs = sorted(runs, key=lambda row: (run_start(row) or parse_time(row[3]) or 0, row[1]))
    # The live run is the latest started real run; runs made up for loose
    # items count only in a thread that has no real runs.
    started = [index for index, row in enumerate(runs) if run_start(row) is not None]
    real = [index for index in started if not runs[index][0].startswith("pseudo:")]
    latest = (real or started or [None])[-1]
    for index, (run_id, _, status, requested_at, completed_at, payload_json) in enumerate(runs):
        run = json.loads(payload_json)
        run_items = by_run.get(run_id, [])
        for _, kind, _, payload in run_items:
            if kind == "user_message":
                stats["userMessages"] += 1
                at = parse_time(payload.get("startedAt"))
                if at is not None:
                    requests.append({"at": at, "text": label(payload.get("text"), REQUEST_MAX),
                                     "intent": payload.get("inputIntent")})
                if payload.get("inputIntent") in ("promoted_queued_to_steer", "steer"):
                    stats["steers"] += 1
            elif kind == "compaction":
                stats["compactions"] += 1
        start = run_start(runs[index])
        if start is None:
            continue
        end = parse_time(completed_at)
        if end is None:
            # The latest started run, when live, lasts until now. Any other run
            # without a completion time (cancelled, or left behind by a
            # restart) lasts until its last item, so the wait after it is not
            # charged to the agent and later runs keep their time.
            if status in LIVE_RUN and index == latest:
                end = now
            else:
                times = [parse_time(p.get("completedAt")) or parse_time(p.get("startedAt")) for _, _, _, p in run_items]
                end = max([start] + [t for t in times if t is not None])
        if status == "interrupted":
            stats["interruptedRuns"] += 1
        if status == "failed":
            stats["failedRuns"] += 1
        # The first user message or notice in the run says who started it;
        # bookkeeping items such as a subagent update can come before it.
        first = next((item for item in run_items if item[1] in ("user_message", "notification")), None)
        trigger = "user"
        wake = None
        generic = False
        if first and first[1] == "notification":
            trigger = "wake"
            wake = wake_category(first[3].get("summary"), first[3].get("source"))
            # A generic notice ("Background activity updated") names nothing:
            # charge the wait to the background work started last.
            generic = wake == "waiting"
            if generic and background:
                wake = background
            stats["wakeups"] += 1

        # Preparing a run (its workspace, the provider) between its request
        # and its start is a wait, or idle when it is as long as an idle gap
        # (a host asleep overnight); the user's part of a gap ends at the
        # request. A request still pending while an earlier-started run
        # finished counts from that run's end.
        requested = parse_time(requested_at)
        gap_end = start
        if requested is not None and requested < start:
            gap_end = max(requested, prev_end or requested)
            if start > gap_end:
                if start - gap_end > idle_minutes * 60:
                    human["idle"] += start - gap_end
                    timeline.append((gap_end, start, "idle", False))
                else:
                    waits["waiting"] += start - gap_end
                    timeline.append((gap_end, start, "waiting", True))
        # Between runs: the user's turnaround, a background wait, or idle.
        if prev_end is not None and gap_end > prev_end:
            start, real_start = gap_end, start
            gap = start - prev_end
            # A long wait ended by a generic notice says nothing about what the
            # thread waited on; like a long silence, it is idle.
            if trigger == "wake" and not (generic and gap > idle_minutes * 60):
                cat = wake
                waits[cat] += gap
            else:
                cat = "idle" if gap > idle_minutes * 60 else "user"
                human[cat] += gap
            timeline.append((prev_end, start, cat, trigger == "wake"))
            start = real_start

        # Inside a run. The agent issues calls in batches (parallel calls start
        # together) and can issue the next batch only when every foreground
        # call of the previous one has returned. A call still running when the
        # next batch starts was running in the background: it owns time only
        # until the batch's last foreground call returned (or, alone, until
        # the next batch). A batch's time, including the model time spent
        # writing it, belongs to the call it waited on longest (a foreground
        # call before a background one), so concurrent calls are never counted
        # twice. T3's own question and approval records are not
        # calls: they take no time themselves, but their waits are carved out
        # below. A queued run can start before the previous one has finished;
        # its time starts after.
        cursor = max(start, prev_end or start)
        tools = []
        for _, kind, item_status, payload in run_items:
            cat = item_category(kind, payload)
            if cat is None:
                continue
            t0 = parse_time(payload.get("startedAt"))
            if t0 is None:
                continue
            # An unfinished item runs until now (or the run's end); a question
            # answered by a later message takes no time of its own.
            t1 = parse_time(payload.get("completedAt")) or (min(now, end) if item_status in LIVE_ITEM else t0)
            if payload.get("responseMode") == "message":
                t1 = t0
            tools.append((t0, min(max(t1, t0), end), cat, kind, item_status, payload))
        tools.sort(key=lambda t: t[0])
        # Claude's AskUserQuestion call is paired with T3's question item; when
        # that item is answered by a later message, the call stops nothing.
        async_asks = [t[0] for t in tools if t[3] == "user_input_request" and t[5].get("responseMode") == "message"]
        questions = []
        calls = []
        for t0, t1, cat, kind, item_status, payload in tools:
            counts[cat] += 1
            command = shell_command(kind, payload)
            if item_status == "failed" or (command is not None and payload.get("exitCode") not in (None, 0)):
                failures[cat] += 1
            if payload.get("toolName") == "AskUserQuestion" and any(abs(t0 - a) < 2 for a in async_asks):
                t1 = t0
            elif is_question(kind, payload) and t1 > t0:
                questions.append((t0, t1))
            if command is not None:
                text = command
                for target in review_targets(text, repo):
                    reviews[target] = reviews.get(target, 0) + 1
                repo = last_repo(text, repo)
            elif kind == "subagent":
                text = payload.get("title") or payload.get("prompt")
                background = "delegation"
            elif payload.get("toolName") == "Monitor":
                tool_input = payload.get("input")
                text = (tool_input.get("description") if isinstance(tool_input, dict) else None) or "Monitor"
                background = wake_category(text)
            elif kind == "web_search":
                text = "Web search"
            elif kind == "file_change":
                text = f"Edit {payload.get('fileName') or 'files'}"
            else:
                text = payload.get("toolName")
            if cat in ("test", "build", "review", "ci", "deploy") and command is not None:
                key = (cat, re.sub(r"\b[0-9a-f]{7,40}\b", "<sha>", label(text)))
                checks[key] = checks.get(key, 0) + 1
            if kind not in RECORDS:
                calls.append({"t0": t0, "t1": t1, "cat": cat, "label": label(text),
                              "longest": not is_question(kind, payload)})
        batches = []
        for call in calls:
            if not batches or call["t0"] - batches[-1][0]["t0"] > BATCH_SECONDS:
                batches.append([])
            batches[-1].append(call)
        segments = []
        for position, batch in enumerate(batches):
            # Only a real next batch shows that a call still running then was
            # in the background; the last batch runs until the run's end.
            has_next = position + 1 < len(batches)
            next_start = batches[position + 1][0]["t0"] if has_next else end
            returned = [c["t1"] for c in batch if c["t1"] <= next_start]
            batch_end = max(returned) if returned else next_start
            for call in batch:
                call["background"] = has_next and call["t1"] > next_start and bool(returned)
                call["owned_end"] = max(call["t0"], min(call["t1"], next_start, batch_end if call["background"] else end))
            for call in sorted(batch, key=lambda c: (-c["owned_end"], c["background"])):
                if call["owned_end"] > cursor:
                    segments.append((cursor, call["owned_end"], call["cat"], id(call)))
                    cursor = call["owned_end"]
        if end > cursor:
            segments.append((cursor, end, "discussion", None))
        # A blocking question or approval stops the agent: its wait is the
        # user's, or idle when it is as long as an idle gap between runs,
        # whatever call was open meanwhile.
        for q0, q1 in merge_intervals(questions):
            wait_cat = "idle" if q1 - q0 > idle_minutes * 60 else "user"
            segments = carve(segments, q0, q1, wait_cat)
        owned = {}
        for t0, t1, cat, owner in segments:
            if cat in HUMAN:
                human[cat] += t1 - t0
            else:
                totals[cat] += t1 - t0
                owned[owner] = owned.get(owner, []) + [(t0, t1)]
            timeline.append((t0, t1, cat, False))
        # Longest items: the time each call owned while it ran, without the
        # model time before it or waits carved out for the user.
        for call in calls:
            if call["longest"]:
                run_time = sum(max(0.0, b - max(a, call["t0"])) for a, b in owned.get(id(call), []))
                longest.append({"category": call["cat"], "seconds": round(run_time), "label": call["label"],
                                "at": iso(call["t0"])})
        prev_end = max(prev_end or end, end)

    agent = sum(totals.values())
    active = agent + sum(waits.values())
    first = min((t0 for t0, _, _, _ in timeline), default=None)
    span = (prev_end - first) if first is not None and prev_end else 0
    longest.sort(key=lambda r: r["seconds"], reverse=True)
    repeated = sorted(
        ({"category": c, "label": l, "count": n} for (c, l), n in checks.items() if n > 2),
        key=lambda r: r["count"],
        reverse=True,
    )
    # Each user message owns the time until the next one, including the wait
    # for the user's reply to it.
    requests.sort(key=lambda r: r["at"])
    starts = [r["at"] for r in requests]
    for request in requests:
        request["seconds"] = {}
    for t0, t1, cat, _ in timeline:
        while requests and t0 < t1:
            index = max(0, bisect.bisect_right(starts, t0) - 1)
            edge = min(t1, starts[index + 1]) if index + 1 < len(starts) and starts[index + 1] > t0 else t1
            row = requests[index]["seconds"]
            row[cat] = row.get(cat, 0) + edge - t0
            t0 = edge
    request_rows = []
    for number, request in enumerate(requests, 1):
        seconds = {c: round(v) for c, v in sorted(request["seconds"].items()) if v >= 1}
        request_rows.append({
            "number": number,
            "at": iso(request["at"]),
            "intent": request["intent"],
            "text": request["text"],
            "activeSeconds": sum(v for c, v in seconds.items() if c not in HUMAN),
            "seconds": seconds,
        })
    if len(request_rows) > MAX_REQUESTS:
        keep = sorted(request_rows, key=lambda r: r["activeSeconds"], reverse=True)[:MAX_REQUESTS]
        request_rows = sorted(keep, key=lambda r: r["number"])
    bin_minutes, bins = bin_timeline(timeline, first, prev_end) if first is not None and prev_end else (None, [])
    return {
        "threadId": thread,
        "title": title,
        "start": iso(first) if first is not None else None,
        "end": iso(prev_end) if prev_end else None,
        "spanSeconds": round(span),
        "activeSeconds": round(active),
        "agentSeconds": round(agent),
        "waitSeconds": round(active - agent),
        "userSeconds": round(human["user"]),
        "idleSeconds": round(human["idle"]),
        "categories": [
            {
                "category": c,
                "seconds": round(totals[c] + waits[c]),
                "agentSeconds": round(totals[c]),
                "waitSeconds": round(waits[c]),
                "share": round((totals[c] + waits[c]) / active, 3) if active else 0,
                "items": counts[c],
                "failed": failures[c],
            }
            for c in CATEGORIES
        ],
        "churn": stats | {"failedItems": sum(failures.values())},
        "reviewRuns": {
            "total": sum(reviews.values()),
            "prs": len(reviews),
            "top": [
                {"target": t, "count": n}
                for t, n in sorted(reviews.items(), key=lambda r: r[1], reverse=True)[:10]
                if n > 1
            ],
        },
        "repeated": repeated[:15],
        "longest": longest[:15],
        "requests": request_rows,
        "binMinutes": bin_minutes,
        "timeline": bins,
    }


def main():
    parser = argparse.ArgumentParser(prog=PROG, description=__doc__.split("\n\n")[0])
    parser.add_argument("thread", help="T3 thread ID")
    parser.add_argument("--db", action="append", default=[], help="state database to try (repeatable)")
    parser.add_argument("--idle-minutes", type=float, default=30, help="gap before a user message that counts as idle (default 30)")
    try:
        args = parser.parse_args()
    except SystemExit as exc:
        sys.exit(0 if exc.code == 0 else 64)
    paths = args.db or [p for p in os.environ.get("T3_STATE_DBS", "").split(":") if p]
    if not paths:
        fail(64, "no state database: pass --db or set T3_STATE_DBS")
    path, db = open_db(paths, args.thread)
    title, _, runs, items = load(db, args.thread)
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    try:
        report = analyse(args.thread, title, runs, items, args.idle_minutes, now)
    except (AttributeError, KeyError, TypeError, ValueError) as err:
        # A payload of an unexpected shape: T3 changed what it stores.
        fail(3, f"unexpected payload shape ({type(err).__name__}: {err}); T3's schema may have changed")
    print(json.dumps({"database": path, "generatedAt": iso(now), "idleMinutes": args.idle_minutes} | report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
