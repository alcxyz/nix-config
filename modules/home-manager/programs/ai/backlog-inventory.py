"""List open issues and pull requests across the user's forges as JSON (ADR-0093).

One read-only pass over the Forgejo API, plus `gh` for GitHub-first
repositories (those Forgejo mirrors from the user's own GitHub account), the
GitHub repositories of configured groups and the user's open pull requests
upstream. `--scope` narrows the run to repositories or groups; groups come
from a scope file. Every row carries computed signals and a lane; issue and
pull request bodies are read here and never printed, so the output stays small
and holds no untrusted prose beyond titles and the short `next` text of an
issue's status line. Items in repositories outside the scope that a row
references are pulled in once, and `--branches` adds leftover remote branches.

Exit codes: 2 no readable Forgejo token, 3 a Forgejo request failed, 64 usage
(including an unknown scope or a malformed scope file). GitHub failures do not
fail the run: `sources.github` says what went wrong.
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
RELATED_PER_SOURCE = 5
BRANCHES_PER_REPO = 100
# Long-lived and tool-managed branches never count as leftovers (GitOps ADR-030 keeps dev, dev-* and develop).
KEPT_BRANCHES = {"main", "master", "dev", "develop", "gh-pages"}
KEPT_BRANCH_PREFIXES = ("dev-", "renovate/")
SCOPE_REPO_RE = re.compile(r"(gh:)?([\w.-]+/[\w.-]+)")
GROUP_RE = re.compile(r"[A-Za-z0-9][\w.-]*")
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
# Links to an issue or pull request in another repository, on either forge.
LINK_RE = re.compile(
    r"https?://(?P<host>[\w.:-]+)/(?P<o1>[\w.-]+)/(?P<r1>[\w.-]+)/(?:issues|pulls|pull)/(?P<n1>\d+)"
    r"|(?<![\w/.:-])(?P<o2>[\w-][\w.-]*)/(?P<r2>[\w.-]+)#(?P<n2>\d+)\b"
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

    def pages(self, path, params, limit=50, cap=None):
        """Every row, or once more than `cap` rows are read, those."""
        rows, page = [], 1
        while True:
            batch = self.get(path, {**params, "limit": limit, "page": page})
            # Forgejo may cap the page size below `limit`, so only an empty page ends the list.
            if not batch:
                return rows
            rows.extend(batch)
            if cap is not None and len(rows) > cap:
                return rows
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


def links(text, forge, repo, forgejo_host):
    """Issues and PRs a text links in other repositories: {(forge, repo, number)}."""
    found = set()
    for match in LINK_RE.finditer(text or ""):
        if match.group("host"):
            host = match.group("host").lower()
            if host == forgejo_host.lower():
                target_forge = "forgejo"
            elif host in {"github.com", "www.github.com"}:
                target_forge = "github"
            else:
                continue
            owner, name, number = match.group("o1"), match.group("r1"), match.group("n1")
        else:
            target_forge, owner, name, number = forge, match.group("o2"), match.group("r2"), match.group("n2")
        name = name.removesuffix(".git")
        # Issue text is untrusted: never build an API path from a dot-only segment.
        if {"."} >= set(owner) or {"."} >= set(name):
            continue
        target = f"{owner}/{name}"
        if (target_forge, target.lower()) != (forge, repo.lower()):
            found.add((target_forge, target, int(number)))
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


def review_decision(reviews):
    """GitHub's reviewDecision from Forgejo reviews: each reviewer's latest verdict, unless it was dismissed."""
    latest = {}
    for review in sorted(reviews, key=lambda r: r.get("id") or 0):
        if review.get("state") in {"APPROVED", "REQUEST_CHANGES"}:
            latest[(review.get("user") or {}).get("login")] = review
    # A dismissed verdict clears the reviewer's say; an older one does not come back.
    states = {review["state"] for review in latest.values() if not review.get("dismissed")}
    if "REQUEST_CHANGES" in states:
        return "changes-requested"
    if "APPROVED" in states:
        return "approved"
    return None


def issue_row(forge, repo, raw, now, ref, host):
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
        "links": links(f"{raw['title']}\n{body}", forge, repo, host),
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


def load_groups(path):
    """Groups from the scope file: {name: {"description", "repos": ["OWNER/REPO" or "gh:OWNER/REPO"]}}."""
    if not path:
        return {}
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, UnicodeDecodeError, ValueError) as error:
        raise Fail(64, f"cannot read the scope file {path}: {error}") from None
    groups = data.get("groups") if isinstance(data, dict) else None
    if not isinstance(groups, dict):
        raise Fail(64, f"the scope file {path} needs an object {{\"groups\": {{NAME: {{\"repos\": [...]}}}}}}")
    for name, group in groups.items():
        repos = group.get("repos") if isinstance(group, dict) else None
        if (not GROUP_RE.fullmatch(name) or name == "all" or not isinstance(repos, list) or not repos
                or not all(isinstance(r, str) and SCOPE_REPO_RE.fullmatch(r) for r in repos)
                or not isinstance(group.get("description", ""), str)):
            raise Fail(64, f"scope file group {name!r} needs a name, and repos as OWNER/REPO or gh:OWNER/REPO")
    return groups


def parse_scope(values, groups):
    """Resolve --scope values; none (or "all") means everything, including every group."""
    scope = {"all": not values, "forgejo": set(), "github": set(), "groups": [], "repos": []}

    def add(value):
        match = SCOPE_REPO_RE.fullmatch(value)
        scope["github" if match.group(1) else "forgejo"].add(match.group(2))

    for value in values:
        if value == "all":
            scope["all"] = True
        elif SCOPE_REPO_RE.fullmatch(value):
            add(value)
            scope["repos"].append(value)
        elif value in groups:
            scope["groups"].append(value)
        else:
            raise Fail(64, f"unknown scope {value!r}: use OWNER/REPO, gh:OWNER/REPO, all or a group from the scope file"
                       + (f" ({', '.join(sorted(groups))})" if groups else " (no scope file is configured)"))
    if scope["all"]:
        scope["groups"] = sorted(groups)
    for name in scope["groups"]:
        for value in groups[name]["repos"]:
            add(value)
    return scope


def collect_forgejo(api, now, merged_days, threads, scope):
    user = api.get("/user")["login"]
    listed = api.pages("/user/repos", {})
    repos = [r for r in listed if not r["archived"]]
    known = {r["full_name"]: r for r in repos if not r["mirror"]}
    wanted = (set(known) if scope["all"] else set()) | scope["forgejo"]
    active = {name: known[name] for name in sorted(wanted) if name in known}
    missing = sorted(wanted - set(known))
    mirrors = [r for r in repos if r["mirror"]] if scope["all"] else []
    covered = set(active) | {r["full_name"] for r in mirrors}
    # The token reads only these repositories, so a short ref to any other most likely names a GitHub
    # one. The value says whether it is a mirror: a GitHub repository with the name of a Forgejo-first
    # one is its push mirror, whose issues live here.
    readable = {r["full_name"].lower(): bool(r["mirror"]) for r in listed}
    if not active:
        return user, active, [], [], mirrors, missing, covered, readable

    issues = {}
    for raw in api.pages("/repos/issues/search", {"state": "open", "type": "issues"}):
        repo = raw["repository"]["full_name"]
        if repo in active:
            issues[(repo, raw["number"])] = issue_row("forgejo", repo, raw, now, f"{repo}#{raw['number']}", api.host)

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
        reviews = api.pages(f"/repos/{repo}/pulls/{raw['number']}/reviews", {}) if kind != "bot" else []
        return repo, pull, status, kind, comments, reviews

    prs = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for repo, pull, status, kind, comments, reviews in pool.map(detail, open_prs):
            statuses = [s.get("status") for s in status.get("statuses") or []]
            ref = f"{repo}#{pull['number']}"
            text = f"{pull['title']}\n{pull.get('body') or ''}"
            refs = references(text, repo, api.host)
            for target in refs:
                if target in issues:
                    issues[target]["openPrs"].append(ref)
            prs.append({
                "links": links(text, "forgejo", repo, api.host),
                "ref": ref, "forge": "forgejo", "repo": repo, "number": pull["number"], "url": pull["html_url"],
                "title": short(pull["title"], TITLE_MAX), "author": pull["user"]["login"], "kind": kind,
                "draft": bool(pull.get("draft")), "base": pull["base"]["ref"], "head": pull["head"]["sha"][:12],
                "mergeable": pull.get("mergeable"), "ci": ci_state(statuses),
                "review": review_state(comments, pull["head"]["sha"], pull["base"]["ref"]) if kind == "own" else "n/a",
                "reviewDecision": review_decision(reviews),
                "issues": sorted(f"{r}#{n}" for (r, n) in refs if (r, n) in issues),
                "ageDays": days_since(now, pull["created_at"]), "idleDays": days_since(now, pull["updated_at"]),
                "updatedAt": pull["updated_at"],
                "thread": (threads or {}).get(pull["html_url"].rstrip("/")),
            })

    return user, active, list(issues.values()), prs, mirrors, missing, covered, readable


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


def collect_github(mirrors, explicit, upstream, now, threads, since, forgejo_host):
    """Issues and PRs of GitHub-first repositories and scoped GitHub repositories, and the user's PRs elsewhere."""
    user = gh("api", "user")["login"]
    names = {name.lower(): name for name in sorted(explicit)}
    for mirror in mirrors:
        parsed = urllib.parse.urlparse(mirror.get("original_url") or "")
        parts = parsed.path.strip("/").removesuffix(".git").split("/")
        if parsed.netloc == "github.com" and len(parts) == 2 and parts[0].lower() == user.lower():
            names.setdefault("/".join(parts).lower(), "/".join(parts))
    explicit = {name.lower() for name in explicit}

    def skipped(name, meta):
        # Forks of others' work are skipped unless a scope names them.
        return meta.get("archived") or (meta.get("fork") and name.lower() not in explicit)

    def repo_items(name):
        try:
            meta = gh("api", f"repos/{name}")
        except RuntimeError as error:
            # Only a missing repository is reported as missing; rate limits and outages fail GitHub as a whole.
            if "HTTP 404" not in str(error):
                raise
            return name, None, [], []
        if skipped(name, meta):
            return name, meta, [], []
        return name, meta, gh_pages(f"repos/{name}/issues?state=open&per_page=100"), merged_since(name, since)

    repo_rows, metas, missing, issues, open_prs, merged_prs = {}, {}, [], {}, [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        for name, meta, items, merged in pool.map(repo_items, sorted(names.values())):
            if meta is None or (meta.get("archived") and name.lower() in explicit):
                missing.append(name)
                continue
            if skipped(name, meta):
                continue
            # GitHub answers with the canonical spelling; rows use it.
            name = meta.get("full_name") or name
            metas[name] = meta
            repo_rows[name] = {"forge": "github", "repo": name, "url": meta["html_url"], "updatedAt": meta["pushed_at"]}
            for raw in items:
                if "pull_request" in raw:
                    open_prs.append((name, raw["number"], False))
                else:
                    ref = f"gh:{name}#{raw['number']}"
                    issues[(name, raw["number"])] = issue_row("github", name, raw, now, ref, forgejo_host)
            merged_prs += [(name, pull) for pull in merged]
    # Join only once every repository's issues are known: a PR may name another repository's issue.
    for name, pull in merged_prs:
        text = f"{pull['title']}\n{pull.get('body') or ''}"
        for target, closes in references(text, name, "github.com").items():
            issue = issues.get(target)
            if issue and parse_time(pull["merged_at"]) >= parse_time(issue["createdAt"]):
                issue["mergedPrs"].append({"ref": f"gh:{name}#{pull['number']}", "url": pull["html_url"],
                                           "closes": closes, "mergedAt": pull["merged_at"]})

    if upstream:
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
            text = f"{pull['title']}\n{pull.get('body') or ''}"
            refs = references(text, name, "github.com")
            for target in refs:
                if target in issues:
                    issues[target]["openPrs"].append(ref)
            rollup = pull.get("statusCheckRollup") or []
            checks = [c.get("conclusion") or c.get("status") or c.get("state") for c in rollup]
            prs.append({
                "links": links(text, "github", name, forgejo_host),
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
    return repo_rows, metas, missing, list(issues.values()), prs


def item_ref(forge, repo, number):
    return f"{'gh:' if forge == 'github' else ''}{repo}#{number}"


def collect_related(api, rows, covered, readable, limit, github):
    """Pull in, once, the items rows link in repositories outside the scope (one hop, capped).

    Forgejo items are looked up only in repositories the token can list; GitHub
    items through gh unless GitHub is off or failed."""
    existing = {row["ref"].lower() for row in rows}
    targets = {}
    for row in rows:
        picked = 0
        for forge, repo, number in sorted(row["links"]):
            ref = item_ref(forge, repo, number)
            if ((forge, repo.lower()) in covered or ref.lower() in existing
                    or (forge == "forgejo" and repo.lower() not in readable)
                    or (forge == "github" and (not github or readable.get(repo.lower()) is False))):
                continue
            if ref not in targets:
                if len(targets) >= limit or picked >= RELATED_PER_SOURCE:
                    continue
                targets[ref] = {"ref": ref, "forge": forge, "repo": repo, "number": number, "pulledBy": []}
            picked += 1
            targets[ref]["pulledBy"].append(row["ref"])
            row["related"].append(ref)

    def fetch(item):
        try:
            if item["forge"] == "forgejo":
                raw = api.get(f"/repos/{item['repo']}/issues/{item['number']}")
            else:
                raw = gh("api", f"repos/{item['repo']}/issues/{item['number']}")
        except (Fail, RuntimeError, ValueError, subprocess.TimeoutExpired):
            return {**item, "state": "unavailable"}
        pull = raw.get("pull_request")
        state = raw.get("state") or "unknown"
        if pull and (pull.get("merged") or pull.get("merged_at")):
            state = "merged"
        return {**item, "kind": "pr" if pull else "issue", "state": state, "title": short(raw.get("title"), TITLE_MAX),
                "updatedAt": raw.get("updated_at"), "closedAt": raw.get("closed_at")}

    # Every source is kept: the renderer shows the ones on the page.
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        return list(pool.map(fetch, targets.values()))


def kept_branch(name, default):
    return name == default or name in KEPT_BRANCHES or name.startswith(KEPT_BRANCH_PREFIXES)


def branch_row(forge, repo, name, last_commit, pr, now, branch_days):
    """A leftover branch, or None when it is kept, has an open PR or is still recent without one."""
    if pr is None:
        idle = days_since(now, last_commit)
        if idle is None or idle < branch_days:
            return None
        lane = "no-pr"
    elif pr["state"] in {"merged", "closed"}:
        lane = pr["state"]
    else:
        return None
    prefix = "gh:" if forge == "github" else ""
    return {"ref": f"{prefix}{repo}@{name}", "forge": forge, "repo": repo, "branch": name, "lane": lane,
            "lastCommitAt": last_commit, "idleDays": days_since(now, last_commit), "pr": pr}


def forgejo_branches(api, name, repo, now, branch_days):
    branches = api.pages(f"/repos/{name}/branches", {}, cap=BRANCHES_PER_REPO)
    default = repo.get("default_branch")
    candidates = [b for b in branches[:BRANCHES_PER_REPO] if not b.get("protected") and not kept_branch(b["name"], default)]
    if not candidates:
        return [], len(branches) > BRANCHES_PER_REPO
    # Every PR is read: an old branch's PR may be among the oldest, and missing it would make the branch look PR-less.
    latest, open_heads = {}, set()
    for pull in api.pages(f"/repos/{name}/pulls", {"state": "all"}):
        head = pull.get("head") or {}
        if (head.get("repo") or {}).get("full_name", name) != name:
            continue  # a fork's branch of the same name is not this one
        if pull.get("state") == "open":
            open_heads.add(head.get("ref"))
        known = latest.get(head.get("ref"))
        if known is None or (pull.get("updated_at") or "") > (known.get("updated_at") or ""):
            latest[head.get("ref")] = pull
    rows = []
    for branch in candidates:
        if branch["name"] in open_heads:
            continue  # its open PR has a row of its own
        pull = latest.get(branch["name"])
        pr = None
        if pull:
            state = "merged" if pull.get("merged") else pull.get("state")
            pr = {"ref": f"{name}#{pull['number']}", "state": state,
                  "at": pull.get("merged_at") if state == "merged" else pull.get("closed_at")}
        row = branch_row("forgejo", name, branch["name"], (branch.get("commit") or {}).get("timestamp"), pr, now, branch_days)
        if row:
            rows.append(row)
    return rows, len(branches) > BRANCHES_PER_REPO


GITHUB_BRANCHES = """query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    defaultBranchRef { name }
    refs(refPrefix: "refs/heads/", first: 100) {
      totalCount
      nodes {
        name
        target { ... on Commit { committedDate } }
        associatedPullRequests(first: 1, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes { number state mergedAt closedAt }
        }
        open: associatedPullRequests(states: OPEN) { totalCount }
      }
    }
  }
}"""


def github_branches(name, now, branch_days):
    owner, repo = name.split("/")
    data = gh("api", "graphql", "-f", f"query={GITHUB_BRANCHES}", "-f", f"owner={owner}", "-f", f"name={repo}")
    found = data["data"]["repository"]
    default = (found.get("defaultBranchRef") or {}).get("name")
    # GraphQL shows branch protection only to admins; the REST list filters for any reader. One page is
    # read: with a full page, protection is unknown, so the repository is reported as cut and adds no rows.
    protected = {b["name"] for b in gh("api", f"repos/{name}/branches?protected=true&per_page=100")}
    if len(protected) >= BRANCHES_PER_REPO:
        return [], True
    rows = []
    for ref in found["refs"]["nodes"]:
        if kept_branch(ref["name"], default) or ref["name"] in protected or ref["open"]["totalCount"]:
            continue
        pulls = ref["associatedPullRequests"]["nodes"]
        pr = None
        if pulls:
            pull = pulls[0]
            state = pull["state"].lower()
            pr = {"ref": f"gh:{name}#{pull['number']}", "state": state,
                  "at": pull.get("mergedAt") if state == "merged" else pull.get("closedAt")}
        row = branch_row("github", name, ref["name"], (ref.get("target") or {}).get("committedDate"), pr, now, branch_days)
        if row:
            rows.append(row)
    return rows, found["refs"]["totalCount"] > BRANCHES_PER_REPO


def collect_branches(api, forgejo_repos, github_repos, now, branch_days):
    """Leftover remote branches in the scope's repositories; a failing repository is counted, not fatal."""
    jobs = [("forgejo", name, repo) for name, repo in forgejo_repos.items()] + [("github", name, None) for name in github_repos]

    def run(job):
        forge, name, repo = job
        try:
            if forge == "forgejo":
                return job, *forgejo_branches(api, name, repo, now, branch_days)
            return job, *github_branches(name, now, branch_days)
        except (Fail, RuntimeError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
            return job, None, False

    rows, failed, truncated = [], [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        for (forge, name, _), found, cut in pool.map(run, jobs):
            label = item_ref(forge, name, 0).split("#")[0]
            if found is None:
                failed.append(label)
                continue
            rows += found
            if cut:
                truncated.append(label)
    status = "ok" if not failed else f"partial: {len(failed)} of {len(jobs)} repositories failed ({', '.join(failed[:5])})"
    return rows, status, truncated


def summarize(repo_rows, issues, prs, branches=()):
    """Per-repository counts, ordered by how much is ready for a decision."""
    rows = {key: {**row, "issues": {}, "prs": {}, "openIssues": 0, "openPrs": 0, "branches": 0,
                  "lastActivity": row["updatedAt"]}
            for key, row in repo_rows.items()}
    for item, side in [(i, "issues") for i in issues] + [(p, "prs") for p in prs] + [(b, "branches") for b in branches]:
        key = (item["forge"], item["repo"])
        row = rows.setdefault(key, {"forge": item["forge"], "repo": item["repo"], "url": None, "issues": {},
                                    "prs": {}, "openIssues": 0, "openPrs": 0, "branches": 0, "lastActivity": None})
        if side == "branches":
            row["branches"] += 1
            continue
        row[side][item["lane"]] = row[side].get(item["lane"], 0) + 1
        row["openIssues" if side == "issues" else "openPrs"] += 1
        last = row["lastActivity"]
        if item["updatedAt"] and (not last or parse_time(item["updatedAt"]) > parse_time(last)):
            row["lastActivity"] = item["updatedAt"]
    result = []
    for row in rows.values():
        if not row["openIssues"] and not row["openPrs"] and not row["branches"]:
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
    parser.add_argument("--scope", "--repo", dest="scope", action="append", default=[],
                        help="OWNER/REPO (Forgejo), gh:OWNER/REPO, a group from the scope file, or all (repeatable; default all)")
    parser.add_argument("--scope-file", help="scope file with groups (default: $BACKLOG_SCOPE_FILE)")
    parser.add_argument("--related", type=int, default=30, help="items to pull in from repositories outside the scope (30; 0 = off)")
    parser.add_argument("--branches", action="store_true", help="add leftover remote branches (thorough mode)")
    parser.add_argument("--branch-days", type=int, default=30, help="days before a branch without a PR counts (30)")
    parser.add_argument("--no-github", action="store_true", help="skip GitHub")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exit_:
        return 0 if exit_.code == 0 else 64
    if not (0 < args.stale_days < 10000 and 0 < args.merged_days < 10000 and 0 < args.branch_days < 10000
            and 0 <= args.related <= 500):
        print(f"{PROG}: --stale-days, --merged-days and --branch-days must be positive, --related 0 to 500", file=sys.stderr)
        return 64
    try:
        groups = load_groups(args.scope_file or os.environ.get("BACKLOG_SCOPE_FILE"))
        scope = parse_scope(args.scope, groups)
    except Fail as error:
        print(f"{PROG}: {error}", file=sys.stderr)
        return error.code

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
        user, active, issues, prs, mirrors, missing, covered, readable = collect_forgejo(
            api, now, args.merged_days, threads, scope)
    except Fail as error:
        print(f"{PROG}: {error}", file=sys.stderr)
        return error.code
    repo_rows = {("forgejo", name): {"forge": "forgejo", "repo": name, "url": r["html_url"], "updatedAt": r["updated_at"]}
                 for name, r in active.items()}
    covered = {("forgejo", name.lower()) for name in covered}

    github, gh_metas = "skipped", {}
    if not args.no_github and (scope["all"] or scope["github"]):
        try:
            since = now - datetime.timedelta(days=args.merged_days)
            gh_repos, gh_metas, gh_missing, gh_issues, gh_prs = collect_github(
                mirrors, scope["github"], scope["all"], now, threads, since, api.host)
            repo_rows.update({("github", name): row for name, row in gh_repos.items()})
            issues += gh_issues
            prs += gh_prs
            missing += [f"gh:{name}" for name in gh_missing]
            github = "ok"
        except (OSError, RuntimeError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
            github = f"error: {short(error, 200)}"
    covered |= {("github", name.lower()) for name in scope["github"]} | {("github", name.lower()) for name in gh_metas}

    for row in issues + prs:
        row["related"] = []
    github_lookups = not args.no_github and not github.startswith("error")
    related = collect_related(api, issues + prs, covered, readable, args.related, github_lookups) if args.related else []
    closed = {item["ref"] for item in related if item["state"] in {"closed", "merged"}}

    branches, branch_source, truncated = [], "skipped", []
    if args.branches:
        branches, branch_source, truncated = collect_branches(api, active, sorted(gh_metas), now, args.branch_days)

    for issue in issues:
        issue["lane"], issue["flags"] = issue_lane(issue, args.stale_days, now)
        del issue["createdAt"], issue["dashboard"]
    for pr in prs:
        pr["lane"], pr["flags"] = pr_lane(pr, args.stale_days, threads is not None)
    for row in issues + prs:
        del row["links"]
        if closed.intersection(row["related"]):
            row["flags"].append("related-closed")

    issues.sort(key=lambda i: (i["forge"], i["repo"], i["number"]))
    prs.sort(key=lambda p: (p["forge"], p["repo"], p["number"]))
    branches.sort(key=lambda b: (b["forge"], b["repo"], b["branch"]))
    count = lambda rows: {lane: sum(1 for r in rows if r["lane"] == lane) for lane in sorted({r["lane"] for r in rows})}
    json.dump({
        "generatedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "user": user,
        "staleDays": args.stale_days,
        "mergedDays": args.merged_days,
        "scope": {"kind": "all" if scope["all"] else "selected", "groups": scope["groups"], "repos": scope["repos"],
                  "missing": sorted(missing)},
        "sources": {"forgejo": api.url, "github": github, "threads": "ok" if threads is not None else "none",
                    "related": "ok" if args.related else "off", "branches": branch_source},
        "totals": {"repos": len({(r["forge"], r["repo"]) for r in issues + prs}), "issues": len(issues),
                   "prs": len(prs), "issueLanes": count(issues), "prLanes": count(prs),
                   "related": len(related), "branches": len(branches), "branchLanes": count(branches)},
        "repos": summarize(repo_rows, issues, prs, branches),
        "issues": issues,
        "prs": prs,
        "related": related,
        "branches": branches,
        "branchesTruncated": truncated,
    }, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
