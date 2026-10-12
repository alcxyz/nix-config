"""List open issues and pull requests across the user's forges as JSON (ADR-0093).

One read-only pass over the Forgejo API, plus `gh` for GitHub-first
repositories (those Forgejo mirrors from the user's own GitHub account) and the
user's open pull requests upstream. Every row carries computed signals and a
lane; issue and pull request bodies are read here and never printed, so the
output stays small and holds no untrusted prose beyond titles and the short
`next` text of an issue's status line.

Exit codes: 2 no readable Forgejo token, 3 a Forgejo request failed, 64 usage.
GitHub failures do not fail the run: `sources.github` says what went wrong.
"""

import argparse
import concurrent.futures
import datetime
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

PROG = "backlog-inventory"
BOTS = {"renovate", "renovate[bot]", "dependabot[bot]", "forgejo-actions"}
TITLE_MAX = 120
NEXT_MAX = 160
# `pr-review comment` starts every outcome with this, naming the reviewed head
# and target branch; the merge guard accepts a comment that names both (ADR-0078).
REVIEW_RE = re.compile(r"automated read-only review \(([0-9a-f]{7,40}) on ([^\n]+?)\):", re.I)
STATUS_RE = re.compile(r"\*\*Status \((\d{4}-\d{2}-\d{2})\):?\*\*:?")
STATUS_FIELD_RE = re.compile(r"\b(Next|Owner):\s*(.+?)(?=\s+\b(?:Decided|Next|Owner):|$)", re.S)
CHECKBOX_RE = re.compile(r"^\s*[-*] \[([ xX])\]", re.M)
CLOSING = r"(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)"
REF_RE = re.compile(
    rf"(?:\b(?P<kw>{CLOSING})\s*:?\s+)?"
    r"(?:(?P<url>https?://(?P<host>[\w.:-]+)/(?P<o1>[\w.-]+)/(?P<r1>[\w.-]+)/issues/(?P<n1>\d+))"
    r"|(?<![\w/])(?:(?P<o2>[\w.-]+)/(?P<r2>[\w.-]+))?#(?P<n2>\d+)\b)",
    re.I,
)


class Fail(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Fail on redirects, so the token never follows one to another host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirect refused", headers, fp)


OPENER = urllib.request.build_opener(NoRedirect)


def parse_time(value):
    if not value:
        return None
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def days_since(now, value):
    moment = parse_time(value)
    return None if moment is None else max(0, int((now - moment).total_seconds() // 86400))


def short(text, limit):
    text = " ".join(str(text or "").split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


class Forgejo:
    def __init__(self, url, token):
        self.url = url.rstrip("/")
        self.host = urllib.parse.urlparse(self.url).netloc
        self.token = token

    def get(self, path, params=None):
        query = "?" + urllib.parse.urlencode(params) if params else ""
        request = urllib.request.Request(
            f"{self.url}/api/v1{path}{query}",
            headers={"Authorization": "token " + self.token, "Accept": "application/json"},
        )
        try:
            with OPENER.open(request, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise Fail(3, f"GET {path} returned HTTP {error.code}") from None
        except (urllib.error.URLError, OSError, ValueError) as error:
            raise Fail(3, f"GET {path} failed: {error}") from None

    def pages(self, path, params, limit=50):
        rows, page = [], 1
        while True:
            batch = self.get(path, {**params, "limit": limit, "page": page})
            # Forgejo may cap the page size below `limit`, so only an empty page ends the list.
            if not batch:
                return rows
            rows.extend(batch)
            page += 1


def gh(*args):
    """Run gh and parse its JSON output; gh keeps its credentials to itself."""
    result = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=120, check=False)
    if result.returncode != 0:
        lines = result.stderr.strip().splitlines()
        raise RuntimeError(f"gh {args[0]} {args[1] if len(args) > 1 else ''}: {lines[-1] if lines else 'failed'}")
    return json.loads(result.stdout or "null")


def gh_pages(path):
    """gh api --paginate --slurp yields one list per page."""
    return [row for page in gh("api", "--paginate", "--slurp", path) for row in page]


def status_line(body, now):
    match = STATUS_RE.search(body)
    if not match:
        return None
    try:
        datetime.date.fromisoformat(match.group(1))
    except ValueError:
        return None  # issue text is untrusted; a malformed date is no status
    paragraph = body[match.end():].split("\n\n", 1)[0]
    fields = {name.lower(): value.strip() for name, value in STATUS_FIELD_RE.findall(paragraph)}
    owner = fields.get("owner", "").rstrip(".").split()
    return {
        "date": match.group(1),
        "ageDays": days_since(now, match.group(1) + "T00:00:00+00:00"),
        "owner": owner[0].rstrip(".,;") if owner else None,
        "next": short(fields["next"], NEXT_MAX) if "next" in fields else None,
    }


def checkboxes(body):
    marks = CHECKBOX_RE.findall(body)
    return {"done": sum(1 for m in marks if m != " "), "total": len(marks)} if marks else None


def references(text, repo, host):
    """Issue references in a PR's title and body: {(repo, number): closes}."""
    found = {}
    for match in REF_RE.finditer(text or ""):
        if match.group("url"):
            if match.group("host") != host:
                continue
            target = (f"{match.group('o1')}/{match.group('r1')}", int(match.group("n1")))
        else:
            other = f"{match.group('o2')}/{match.group('r2')}" if match.group("o2") else repo
            target = (other, int(match.group("n2")))
        found[target] = found.get(target, False) or bool(match.group("kw"))
    return found


def ci_state(states):
    """Combine check states into success, failure, pending or none."""
    states = [s for s in states if s]
    if not states:
        return "none"
    if any(s in {"failure", "error", "cancelled", "timed_out", "action_required"} for s in states):
        return "failure"
    if any(s in {"pending", "queued", "in_progress", "waiting", "expected", "running"} for s in states):
        return "pending"
    return "success"


def review_state(comments, head, base):
    """Whether a pr-review outcome names this head and target branch, as the merge guard requires."""
    reviewed = [m.groups() for c in comments if (m := REVIEW_RE.match((c.get("body") or "").lstrip()))]
    if not reviewed:
        return "none"
    current = any(head.lower().startswith(sha.lower()) and target == base for sha, target in reviewed)
    return "head" if current else "outdated"


def issue_row(forge, repo, raw, now, ref):
    body = raw.get("body") or ""
    return {
        "ref": ref,
        "forge": forge,
        "repo": repo,
        "number": raw["number"],
        "url": raw["html_url"],
        "title": short(raw["title"], TITLE_MAX),
        "author": raw["user"]["login"],
        "ageDays": days_since(now, raw["created_at"]),
        "idleDays": days_since(now, raw["updated_at"]),
        "updatedAt": raw["updated_at"],
        "comments": raw.get("comments", 0),
        "labels": sorted(label["name"] for label in raw.get("labels") or []),
        "milestone": (raw.get("milestone") or {}).get("title"),
        "assignees": sorted(a["login"] for a in raw.get("assignees") or []),
        "checks": checkboxes(body),
        "status": status_line(body, now),
        "openPrs": [],
        "mergedPrs": [],
        "dashboard": is_bot(raw["user"]["login"]) and "dashboard" in raw["title"].lower(),
        "createdAt": raw["created_at"],
    }


def issue_lane(issue, stale_days, now):
    flags = []
    checks = issue["checks"]
    if checks and 0 < checks["done"] < checks["total"]:
        flags.append("partly-done")
    if any(not pr["closes"] for pr in issue["mergedPrs"]):
        flags.append("mentioned-by-merged-pr")
    # Nobody touched the issue in the three days since work that names it landed: maybe done.
    updated = parse_time(issue["updatedAt"])
    slack, grace = datetime.timedelta(hours=1), now - datetime.timedelta(days=3)
    if any(updated <= parse_time(pr["mergedAt"]) + slack and parse_time(pr["mergedAt"]) <= grace
           for pr in issue["mergedPrs"]):
        flags.append("untouched-since-merge")
    if any("block" in label.lower() for label in issue["labels"]):
        flags.append("blocked")
    if "validation-needed" in issue["labels"]:
        flags.append("validation-needed")
    status = issue["status"]
    if status and status["ageDays"] is not None and status["ageDays"] >= stale_days:
        flags.append("status-stale")
    if issue["dashboard"]:
        lane = "dashboard"
    elif any(pr["closes"] for pr in issue["mergedPrs"]) or (checks and checks["done"] == checks["total"]):
        lane = "close"
    elif issue["openPrs"]:
        lane = "inflight"
    elif issue["idleDays"] >= stale_days:
        lane = "stale"
    else:
        lane = "active"
    return lane, flags


def pr_lane(pr, stale_days, threads_known):
    flags = []
    if pr["draft"]:
        flags.append("draft")
    # Forgejo reports draft PRs as unmergeable, so only a ready PR can conflict. It also
    # reports false for a few seconds while it checks a new head, which looks the same.
    conflict = pr["mergeable"] is False and not pr["draft"]
    if conflict:
        flags.append("conflict")
    if pr["ci"] == "failure":
        flags.append("ci-failed")
    if pr["kind"] == "own" and pr["review"] in {"none", "outdated"}:
        flags.append("review-" + ("missing" if pr["review"] == "none" else "outdated"))
    thread = pr["thread"]
    if thread and thread["bucket"] != "unsettled":
        flags.append("thread-settled")
    if threads_known and pr["kind"] in {"own", "upstream"} and not (thread and thread["bucket"] == "unsettled"):
        flags.append("orphan")
    if pr["reviewDecision"] == "changes-requested":
        flags.append("changes-requested")
    green = not pr["draft"] and pr["ci"] in {"success", "none"} and pr["mergeable"] is True
    if pr["kind"] == "bot":
        lane = "renovate"
    elif thread and thread["bucket"] == "unsettled":
        lane = "inflight"
    elif pr["ci"] == "failure" or conflict or pr["reviewDecision"] == "changes-requested":
        lane = "blocked"
    elif pr["kind"] == "own" and green and pr["review"] == "head":
        lane = "ready"
    elif pr["kind"] == "upstream" and green and pr["reviewDecision"] == "approved":
        lane = "ready"
    elif pr["kind"] == "other" and green:
        # Someone else's PR on your repository waits for your review.
        lane = "review"
    elif pr["idleDays"] >= stale_days:
        lane = "stale"
    elif pr["kind"] == "upstream" and not pr["draft"]:
        lane = "waiting"
    else:
        lane = "open"
    return lane, flags


def is_bot(login):
    return login in BOTS or login.startswith("app/") or login.endswith("[bot]")


def pr_kind(author, user, upstream=False):
    if is_bot(author):
        return "bot"
    if upstream:
        return "upstream"
    return "own" if author == user else "other"


def load_threads(path):
    """Map PR URLs to the T3 thread that holds them (t3-thread-inventory output)."""
    if not path:
        return None
    with open(path, encoding="utf-8") as handle:
        report = json.load(handle)
    held = {}
    # Unsettled threads come first in the inventory, so they win a shared PR.
    for thread in report.get("threads", []):
        for pr in thread.get("prs") or []:
            url = (pr.get("url") or "").rstrip("/")
            if url and url not in held:
                held[url] = {"threadId": thread["threadId"], "title": short(thread.get("title"), TITLE_MAX),
                             "bucket": thread.get("bucket"), "status": thread.get("status")}
    return held


def collect_forgejo(api, now, stale_days, merged_days, threads, only):
    user = api.get("/user")["login"]
    repos = [r for r in api.pages("/user/repos", {}) if not r["archived"]]
    active = {r["full_name"]: r for r in repos if not r["mirror"] and (not only or r["full_name"] in only)}
    mirrors = [r for r in repos if r["mirror"]]

    issues = {}
    for raw in api.pages("/repos/issues/search", {"state": "open", "type": "issues"}):
        repo = raw["repository"]["full_name"]
        if repo in active:
            issues[(repo, raw["number"])] = issue_row("forgejo", repo, raw, now, f"{repo}#{raw['number']}")

    since = (now - datetime.timedelta(days=merged_days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    for raw in api.pages("/repos/issues/search", {"state": "closed", "type": "pulls", "since": since}):
        repo = raw["repository"]["full_name"]
        merged = (raw.get("pull_request") or {}).get("merged_at")
        if repo not in active or not merged or parse_time(merged) < parse_time(since):
            continue
        for target, closes in references(f"{raw['title']}\n{raw.get('body') or ''}", repo, api.host).items():
            issue = issues.get(target)
            if issue and parse_time(merged) >= parse_time(issue["createdAt"]):
                issue["mergedPrs"].append({"ref": f"{repo}#{raw['number']}", "url": raw["html_url"],
                                           "closes": closes, "mergedAt": merged})

    open_prs = [raw for raw in api.pages("/repos/issues/search", {"state": "open", "type": "pulls"})
                if raw["repository"]["full_name"] in active]

    def detail(raw):
        repo = raw["repository"]["full_name"]
        pull = api.get(f"/repos/{repo}/pulls/{raw['number']}")
        head = pull["head"]["sha"]
        status = api.get(f"/repos/{repo}/commits/{head}/status")
        kind = pr_kind(pull["user"]["login"], user)
        comments = api.get(f"/repos/{repo}/issues/{raw['number']}/comments") if kind == "own" else []
        return repo, pull, status, kind, comments

    prs = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for repo, pull, status, kind, comments in pool.map(detail, open_prs):
            statuses = [s.get("status") for s in status.get("statuses") or []]
            ref = f"{repo}#{pull['number']}"
            refs = references(f"{pull['title']}\n{pull.get('body') or ''}", repo, api.host)
            for target in refs:
                if target in issues:
                    issues[target]["openPrs"].append(ref)
            prs.append({
                "ref": ref, "forge": "forgejo", "repo": repo, "number": pull["number"], "url": pull["html_url"],
                "title": short(pull["title"], TITLE_MAX), "author": pull["user"]["login"], "kind": kind,
                "draft": bool(pull.get("draft")), "base": pull["base"]["ref"], "head": pull["head"]["sha"][:12],
                "mergeable": pull.get("mergeable"), "ci": ci_state(statuses),
                "review": review_state(comments, pull["head"]["sha"], pull["base"]["ref"]) if kind == "own" else "n/a",
                "reviewDecision": None,
                "issues": sorted(f"{r}#{n}" for (r, n) in refs if (r, n) in issues),
                "ageDays": days_since(now, pull["created_at"]), "idleDays": days_since(now, pull["updated_at"]),
                "updatedAt": pull["updated_at"],
                "thread": (threads or {}).get(pull["html_url"].rstrip("/")),
            })

    repo_rows = {name: {"forge": "forgejo", "repo": name, "url": r["html_url"], "updatedAt": r["updated_at"]}
                 for name, r in active.items()}
    return user, repo_rows, list(issues.values()), prs, mirrors


def merged_since(name, since):
    """Merged PRs of a GitHub repository since `since`, newest updates first."""
    merged, page = [], 1
    while True:
        batch = gh("api", f"repos/{name}/pulls?state=closed&sort=updated&direction=desc&per_page=100&page={page}")
        merged += [p for p in batch if p.get("merged_at") and parse_time(p["merged_at"]) >= since]
        # A merge updates the PR, so later pages hold only older merges.
        if len(batch) < 100 or parse_time(batch[-1]["updated_at"]) < since:
            return merged
        page += 1


def collect_github(mirrors, now, threads, since):
    """Issues and PRs of GitHub-first repositories, and the user's PRs elsewhere."""
    user = gh("api", "user")["login"]
    names = []
    for mirror in mirrors:
        parsed = urllib.parse.urlparse(mirror.get("original_url") or "")
        parts = parsed.path.strip("/").removesuffix(".git").split("/")
        if parsed.netloc == "github.com" and len(parts) == 2 and parts[0].lower() == user.lower():
            names.append("/".join(parts))

    def repo_items(name):
        meta = gh("api", f"repos/{name}")
        if meta.get("archived") or meta.get("fork"):
            return name, meta, [], []
        return name, meta, gh_pages(f"repos/{name}/issues?state=open&per_page=100"), merged_since(name, since)

    repo_rows, issues, open_prs, merged_prs = {}, {}, [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        for name, meta, items, merged in pool.map(repo_items, names):
            if meta.get("archived") or meta.get("fork"):
                continue
            repo_rows[name] = {"forge": "github", "repo": name, "url": meta["html_url"], "updatedAt": meta["pushed_at"]}
            for raw in items:
                if "pull_request" in raw:
                    open_prs.append((name, raw["number"], False))
                else:
                    ref = f"gh:{name}#{raw['number']}"
                    issues[(name, raw["number"])] = issue_row("github", name, raw, now, ref)
            merged_prs += [(name, pull) for pull in merged]
    # Join only once every repository's issues are known: a PR may name another repository's issue.
    for name, pull in merged_prs:
        text = f"{pull['title']}\n{pull.get('body') or ''}"
        for target, closes in references(text, name, "github.com").items():
            issue = issues.get(target)
            if issue and parse_time(pull["merged_at"]) >= parse_time(issue["createdAt"]):
                issue["mergedPrs"].append({"ref": f"gh:{name}#{pull['number']}", "url": pull["html_url"],
                                           "closes": closes, "mergedAt": pull["merged_at"]})

    for found in gh("search", "prs", "--author", "@me", "--state", "open", "--limit", "100",
                    "--json", "repository,number"):
        name = found["repository"]["nameWithOwner"]
        if name not in repo_rows:
            open_prs.append((name, found["number"], True))

    fields = ("number,title,url,author,isDraft,reviewDecision,baseRefName,headRefOid,mergeable,"
              "statusCheckRollup,createdAt,updatedAt,body")

    def detail(item):
        name, number, upstream = item
        pull = gh("pr", "view", str(number), "--repo", name, "--json", fields)
        kind = pr_kind(pull["author"]["login"], user, upstream)
        comments = gh_pages(f"repos/{name}/issues/{number}/comments?per_page=100") if kind == "own" else []
        return name, upstream, pull, kind, comments

    prs = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        for name, upstream, pull, kind, comments in pool.map(detail, open_prs):
            ref = f"gh:{name}#{pull['number']}"
            refs = references(f"{pull['title']}\n{pull.get('body') or ''}", name, "github.com")
            for target in refs:
                if target in issues:
                    issues[target]["openPrs"].append(ref)
            rollup = pull.get("statusCheckRollup") or []
            checks = [c.get("conclusion") or c.get("status") or c.get("state") for c in rollup]
            prs.append({
                "ref": ref, "forge": "github", "repo": name, "number": pull["number"], "url": pull["url"],
                "title": short(pull["title"], TITLE_MAX), "author": pull["author"]["login"], "kind": kind,
                "draft": bool(pull.get("isDraft")), "base": pull["baseRefName"], "head": pull["headRefOid"][:12],
                "mergeable": {"MERGEABLE": True, "CONFLICTING": False}.get(pull.get("mergeable")),
                "ci": ci_state([str(c).lower() for c in checks if c]),
                "review": review_state(comments, pull["headRefOid"], pull["baseRefName"]) if kind == "own" else "n/a",
                "reviewDecision": (pull.get("reviewDecision") or "").lower().replace("_", "-") or None,
                "issues": sorted(f"gh:{r}#{n}" for (r, n) in refs if (r, n) in issues),
                "ageDays": days_since(now, pull["createdAt"]), "idleDays": days_since(now, pull["updatedAt"]),
                "updatedAt": pull["updatedAt"],
                "thread": (threads or {}).get(pull["url"].rstrip("/")),
            })
    return repo_rows, list(issues.values()), prs


def summarize(repo_rows, issues, prs):
    """Per-repository counts, ordered by how much is ready for a decision."""
    rows = {key: {**row, "issues": {}, "prs": {}, "openIssues": 0, "openPrs": 0, "lastActivity": row["updatedAt"]}
            for key, row in repo_rows.items()}
    for item, side in [(i, "issues") for i in issues] + [(p, "prs") for p in prs]:
        key = (item["forge"], item["repo"])
        row = rows.setdefault(key, {"forge": item["forge"], "repo": item["repo"], "url": None, "issues": {},
                                    "prs": {}, "openIssues": 0, "openPrs": 0, "lastActivity": None})
        row[side][item["lane"]] = row[side].get(item["lane"], 0) + 1
        row["openIssues" if side == "issues" else "openPrs"] += 1
        last = row["lastActivity"]
        if item["updatedAt"] and (not last or parse_time(item["updatedAt"]) > parse_time(last)):
            row["lastActivity"] = item["updatedAt"]
    result = []
    for row in rows.values():
        if not row["openIssues"] and not row["openPrs"]:
            continue
        row.pop("updatedAt", None)
        # Decisions waiting: close candidates and PRs that need a merge or a fix.
        row["actionable"] = row["issues"].get("close", 0) + sum(
            row["prs"].get(lane, 0) for lane in ("ready", "blocked", "renovate", "stale"))
        result.append(row)
    result.sort(key=lambda r: (-r["actionable"], -(r["openIssues"] + r["openPrs"]), r["repo"]))
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(prog=PROG, description=__doc__.split("\n\n")[0])
    parser.add_argument("--stale-days", type=int, default=45, help="idle days before an item counts as stale (45)")
    parser.add_argument("--merged-days", type=int, default=60, help="look back this far for merged PRs (60)")
    parser.add_argument("--threads", help="t3-thread-inventory output, to find the thread holding each PR")
    parser.add_argument("--repo", action="append", default=[], help="limit Forgejo to OWNER/NAME (repeatable)")
    parser.add_argument("--no-github", action="store_true", help="skip GitHub")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exit_:
        return 0 if exit_.code == 0 else 64
    if not (0 < args.stale_days < 10000 and 0 < args.merged_days < 10000):
        print(f"{PROG}: --stale-days and --merged-days must be positive", file=sys.stderr)
        return 64

    # The token goes only to the Forgejo the Nix wrapper pins; there is no flag to change it.
    url = os.environ.get("BACKLOG_FORGEJO_URL", "https://git.alc.xyz")
    try:
        with open(os.environ["FORGEJO_API_TOKEN_FILE"], encoding="utf-8") as handle:
            api = Forgejo(url, handle.read().strip())
    except (KeyError, OSError, UnicodeDecodeError):
        print(f"{PROG}: FORGEJO_API_TOKEN_FILE does not name a readable file", file=sys.stderr)
        return 2

    now = datetime.datetime.now(datetime.timezone.utc)
    try:
        threads = load_threads(args.threads)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"{PROG}: cannot read --threads: {error}", file=sys.stderr)
        return 64
    try:
        user, repo_rows, issues, prs, mirrors = collect_forgejo(
            api, now, args.stale_days, args.merged_days, threads, set(args.repo))
    except Fail as error:
        print(f"{PROG}: {error}", file=sys.stderr)
        return error.code
    repo_rows = {("forgejo", name): row for name, row in repo_rows.items()}

    github = "skipped"
    if not args.no_github and not args.repo:
        try:
            since = now - datetime.timedelta(days=args.merged_days)
            gh_repos, gh_issues, gh_prs = collect_github(mirrors, now, threads, since)
            repo_rows.update({("github", name): row for name, row in gh_repos.items()})
            issues += gh_issues
            prs += gh_prs
            github = "ok"
        except (OSError, RuntimeError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
            github = f"error: {short(error, 200)}"

    for issue in issues:
        issue["lane"], issue["flags"] = issue_lane(issue, args.stale_days, now)
        del issue["createdAt"], issue["dashboard"]
    for pr in prs:
        pr["lane"], pr["flags"] = pr_lane(pr, args.stale_days, threads is not None)

    issues.sort(key=lambda i: (i["forge"], i["repo"], i["number"]))
    prs.sort(key=lambda p: (p["forge"], p["repo"], p["number"]))
    count = lambda rows: {lane: sum(1 for r in rows if r["lane"] == lane) for lane in sorted({r["lane"] for r in rows})}
    json.dump({
        "generatedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "user": user,
        "staleDays": args.stale_days,
        "mergedDays": args.merged_days,
        "sources": {"forgejo": api.url, "github": github, "threads": "ok" if threads is not None else "none"},
        "totals": {"repos": len({(r["forge"], r["repo"]) for r in issues + prs}), "issues": len(issues),
                   "prs": len(prs), "issueLanes": count(issues), "prLanes": count(prs)},
        "repos": summarize(repo_rows, issues, prs),
        "issues": issues,
        "prs": prs,
    }, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
