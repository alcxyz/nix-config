"""List the Git worktrees of the repositories under a source root, with cleanup facts, as JSON (ADR-0093).

Read-only: it never removes, prunes, moves or changes a worktree or branch. (`git merge-tree` does store the
trees it computes as unreferenced objects, which gc collects.)
`--fetch` runs `git fetch` without pruning or maintenance and lists the remote's live
branches, so a deleted upstream branch shows as gone. Pull requests are looked
up on Forgejo (the token file is read inside the process and sent only to the
pinned URL) or, for GitHub remotes and Forgejo mirrors of GitHub, with `gh`.
`--save` keeps this run as the snapshot the next run reports changes against.

Exit codes: 64 usage. Forge failures do not fail the run: `sources` and each
row's `prError` say what went wrong.
"""

import argparse
import concurrent.futures
import datetime
import glob
import http.client
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

PROG = "worktree-audit"
# Long-lived branches never identify a pull request by name: dev is the head of every promotion PR.
KEPT_BRANCHES = {"main", "master", "dev", "develop", "gh-pages"}
# Directory names not searched for repositories.
SKIP_DIRS = {".git", "node_modules", ".direnv", "target", "result", "vendor", "dist", "build", ".venv",
             "__pycache__", ".cache"}
# Ignored entries that a build or tool recreates, so they never hold work.
REBUILDABLE = {"node_modules", ".direnv", "result", "target", "dist", "build", ".venv", "venv", "__pycache__",
               ".pytest_cache", ".mypy_cache", ".ruff_cache", ".next", ".turbo", ".gradle", ".terraform",
               "coverage", ".DS_Store"}
CONFLICTS = {"DD", "AU", "UD", "UA", "DU", "AA", "UU"}
# Lanes in the order they are reported: what most needs attention comes first.
LANES = ["missing", "unreadable", "in-use", "damaged", "uncommitted", "merged-diverged", "unpushed", "open-pr",
         "closed-pr", "no-pr", "check-ignored", "removable"]
SAMPLE = 5
PR_PAGES = 40
FETCH_TIMEOUT = 60
# Branch pull requests may predate the branch's local creation (a checkout of an existing PR branch).
BRANCH_MARGIN = 30 * 86400
# Reflog subjects of the entry that creates a branch: git branch, checkout -b, switch -c, worktree add -b, clone.
CREATED = ("branch: Created from", "clone: from")
SCP_RE = re.compile(r"^(?:[\w.-]+@)?(?P<host>[\w.-]+):(?!\d+/)(?P<path>[^\\]+?)(?:\.git)?/?$")
URL_RE = re.compile(r"^(?:ssh|https?|git)://(?:[^@/]+@)?(?P<host>[\w.-]+)(?::\d+)?/(?P<path>.+?)(?:\.git)?/?$")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Fail on redirects, so the token never follows one to another host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirect refused", headers, fp)


OPENER = urllib.request.build_opener(NoRedirect)


class ForgeError(Exception):
    pass


def iso(timestamp):
    if timestamp is None:
        return None
    return datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(value):
    if not value:
        return None
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


GIT_ENV = {**os.environ, "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"}


def git(path, *args, check=True, stdin=None, timeout=120):
    """Run git in `path` without taking optional locks, so `status` never rewrites the index.

    With `check=False` a timeout is a failed result (exit 124), so one hung remote cannot stop the run. Output is
    decoded with surrogateescape: reflog subjects and file names need not be UTF-8, and paths round-trip to os calls.
    """
    try:
        result = subprocess.run(["git", "-C", path, "--no-optional-locks", *args], input=stdin,
                                capture_output=True, text=True, encoding="utf-8", errors="surrogateescape",
                                timeout=timeout, check=False, env=GIT_ENV)
    except subprocess.TimeoutExpired:
        if check:
            raise
        return subprocess.CompletedProcess(args, 124, "", "timed out")
    if check and result.returncode != 0:
        raise RuntimeError(f"git {args[0]}: {result.stderr.strip().splitlines()[-1:] or 'failed'}")
    return result



def parse_remote(url):
    """(host, OWNER/REPO) of a remote URL; credentials in the URL are dropped, never returned."""
    for pattern in (URL_RE, SCP_RE):
        match = pattern.match(url.strip())
        if match:
            parts = [p for p in match.group("path").split("/") if p]
            if len(parts) >= 2:
                return match.group("host").lower(), "/".join(parts[-2:])
    return None, None


def find_repos(root, depth, skip):
    """Main checkouts (directories holding a `.git` directory) under `root`, at most `depth` levels down."""
    repos = []

    def walk(path, level):
        try:
            entries = list(os.scandir(path))
        except OSError:
            return
        if any(e.name == ".git" and e.is_dir(follow_symlinks=False) for e in entries):
            repos.append(path)
        if level >= depth:
            return
        for entry in entries:
            if (entry.is_dir(follow_symlinks=False) and entry.name not in SKIP_DIRS
                    and os.path.realpath(entry.path) not in skip):
                walk(entry.path, level + 1)

    walk(root, 0)
    return sorted(repos)


def list_worktrees(repo):
    """Linked worktrees of a repository from `git worktree list --porcelain -z`; the main checkout is skipped."""
    out = git(repo, "worktree", "list", "--porcelain", "-z", check=False).stdout
    rows, row = [], {}
    for field in out.split("\0"):
        if not field:
            if row:
                rows.append(row)
            row = {}
            continue
        key, _, value = field.partition(" ")
        row[key] = value if value else True
    if row:
        rows.append(row)
    return [r for r in rows[1:] if "bare" not in r]


def scan_processes():
    """(working directory, pid, command name) of every process this user can read, except this one.

    None where there is no /proc (macOS): processes are then unknown, not absent.
    """
    if not os.path.isdir("/proc"):
        return None
    found = []
    for name in os.listdir("/proc"):
        if not name.isdigit() or int(name) == os.getpid():
            continue
        try:
            cwd = os.readlink(f"/proc/{name}/cwd")
            # The kernel cuts comm at 15 bytes, possibly inside a multibyte character.
            with open(f"/proc/{name}/comm", encoding="utf-8", errors="replace") as handle:
                comm = handle.read().strip()
        except OSError:
            continue
        found.append((cwd.removesuffix(" (deleted)"), int(name), comm))
    return found


def kind_of(real, roots):
    def under(base):
        return base is not None and (real == base or real.startswith(base + "/"))

    # Claude Code nests its worktrees inside any checkout, including a manual worktree.
    if "/.claude/worktrees/" in real + "/":
        return "claude"
    if under(roots["worktrees"]):
        return "manual"
    if any(under(t) for t in roots["t3"]):
        return "t3"
    if any(under(t) for t in roots["tmp"]):
        return "tmp"
    return "other"


def parse_status(out):
    counts = {"modified": 0, "untracked": 0, "deleted": 0, "conflicted": 0}
    fields = out.split("\0")
    i = 0
    while i < len(fields):
        entry = fields[i]
        i += 1
        if len(entry) < 4:
            continue
        xy = entry[:2]
        if xy[0] in "RC":
            i += 1  # the rename's original path
        if xy == "??":
            counts["untracked"] += 1
        elif xy in CONFLICTS:
            counts["conflicted"] += 1
        elif xy[1] == "D" and xy[0] != "D":
            counts["deleted"] += 1
        else:
            counts["modified"] += 1
    return counts


def remote_info(repo, fetch):
    """The repository's forge identity and, with `fetch`, its live branch tips."""
    remotes = git(repo, "remote", check=False).stdout.split()
    remote = "origin" if "origin" in remotes else (remotes[0] if remotes else None)
    info = {"remote": remote, "remotes": remotes, "host": None, "name": None, "live": None, "tips": [],
            "fetchError": None}
    if remote is None:
        return info
    url = git(repo, "remote", "get-url", remote, check=False).stdout.strip()
    info["host"], info["name"] = parse_remote(url)
    if fetch:
        # Explicit flags, since fetch.prune, remote.*.prune or auto gc (which prunes worktrees) may be configured.
        fetched = git(repo, "-c", "gc.auto=0", "-c", "maintenance.auto=false", "fetch", "--quiet", "--no-prune",
                      "--no-prune-tags", "--no-auto-maintenance", remote, check=False, timeout=FETCH_TIMEOUT)
        listed = git(repo, "ls-remote", "--heads", remote, check=False, timeout=FETCH_TIMEOUT)
        if fetched.returncode != 0 or listed.returncode != 0:
            info["fetchError"] = "timed out" if 124 in (fetched.returncode, listed.returncode) else "fetch failed"
        else:
            live = {}
            for line in listed.stdout.splitlines():
                sha, _, ref = line.partition("\t")
                live[ref.removeprefix("refs/heads/")] = sha
            info["live"] = live
            # Worktrees share the object store, so which live tips are local is a per-repository fact.
            wanted = sorted(set(live.values()))
            checked = git(repo, "cat-file", "--batch-check=%(objectname) %(objecttype)", stdin="\n".join(wanted) + "\n",
                          check=False).stdout.splitlines()
            info["tips"] = [line.split()[0] for line in checked if line.endswith(" commit")]
    return info


def ref_exists(path, ref):
    return git(path, "rev-parse", "--verify", "--quiet", ref + "^{commit}", check=False).returncode == 0


def pick_base(path, remote, pr_base):
    if remote is None:
        return None
    candidates = [pr_base] if pr_base else []
    candidates.append("dev")
    head = git(path, "symbolic-ref", "--quiet", f"refs/remotes/{remote}/HEAD", check=False).stdout.strip()
    if head:
        candidates.append(head.removeprefix(f"refs/remotes/{remote}/"))
    candidates += ["main", "master"]
    for name in candidates:
        if ref_exists(path, f"refs/remotes/{remote}/{name}"):
            return f"{remote}/{name}"
    return None


def containment(path, base):
    """Whether HEAD's changes are in `base`: as an ancestor, or by content (a squash merge), with the rest's size."""
    if git(path, "merge-base", "--is-ancestor", "HEAD", base, check=False).returncode == 0:
        return True, None
    merged = git(path, "merge-tree", "--write-tree", base, "HEAD", check=False)
    tree = merged.stdout.split("\n", 1)[0].strip()
    if merged.returncode == 0 and tree == git(path, "rev-parse", base + "^{tree}").stdout.strip():
        return True, None
    if merged.returncode == 0:
        # What merging HEAD would still add to the base.
        stat = git(path, "diff", "--shortstat", base, tree).stdout
    else:
        # The merge conflicts, so report HEAD's own changes since it forked instead.
        fork = git(path, "merge-base", base, "HEAD", check=False).stdout.strip()
        stat = git(path, "diff", "--shortstat", fork, "HEAD").stdout if fork else ""
    numbers = {key: int(n) for n, key in re.findall(r"(\d+) (file|insertion|deletion)", stat)}
    return False, {"conflicts": merged.returncode != 0, "files": numbers.get("file", 0),
                   "added": numbers.get("insertion", 0), "removed": numbers.get("deletion", 0)}


def inspect(entry, repo, info, roots, processes, now, stale_days):
    try:
        return read_worktree(entry, repo, info, roots, processes, now, stale_days)
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        real = os.path.realpath(entry["worktree"])
        kind = kind_of(real, roots)
        return {"path": entry["worktree"], "repo": repo["rel"], "kind": kind, "managed": kind in {"t3", "claude"},
                "branch": None, "head": entry.get("HEAD"), "forge": None, "remoteRepo": info["name"],
                "exists": os.path.isdir(entry["worktree"]), "prunable": "prunable" in entry,
                "processes": processes_in(real, processes), "error": str(error)[:200]}


def read_worktree(entry, repo, info, roots, processes, now, stale_days):
    path = entry["worktree"]
    branch = entry.get("branch")
    branch = branch.removeprefix("refs/heads/") if isinstance(branch, str) else None
    real = os.path.realpath(path)
    row = {
        "path": path,
        "repo": repo["rel"],
        "kind": kind_of(real, roots),
        "branch": branch,
        "head": entry.get("HEAD"),
        "locked": "locked" in entry,
        "forge": None,
        "remoteRepo": info["name"],
        "exists": os.path.isdir(path),
        # Git marks a registration prunable when its directory or its .git file is gone; files may survive the latter.
        "prunable": "prunable" in entry,
    }
    row["managed"] = row["kind"] in {"t3", "claude"}
    if not row["exists"]:
        return row
    # Without its own .git file Git would search upward and read whatever checkout contains the directory.
    if not os.path.lexists(os.path.join(path, ".git")):
        raise RuntimeError("its .git file is gone")
    top = git(path, "rev-parse", "--show-toplevel").stdout.strip()
    if os.path.realpath(top) != real:
        raise RuntimeError(f"Git reads it as part of {top}")

    status = git(path, "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignore-submodules=none").stdout
    row["changes"] = parse_status(status)
    ignored = [e for e in git(path, "ls-files", "-z", "--others", "--ignored", "--exclude-standard",
                              "--directory").stdout.split("\0") if e]
    other = [e for e in ignored if os.path.basename(e.rstrip("/")) not in REBUILDABLE and not e.endswith(".pyc")]
    row["ignored"] = len(ignored)
    row["ignoredOther"] = len(other)
    row["ignoredSample"] = other[:SAMPLE]
    row["submodulesChanged"] = 0
    if os.path.exists(os.path.join(path, ".gitmodules")):
        sub = git(path, "submodule", "status", "--recursive", check=False).stdout.splitlines()
        row["submodulesChanged"] = sum(1 for line in sub if line[:1] in "+U")

    commit_time = int(git(path, "log", "-1", "--format=%ct", "HEAD").stdout.strip() or 0) or None
    newest = None
    for name in git(path, "ls-files", "-z", "--cached", "--others", "--exclude-standard").stdout.split("\0"):
        if not name:
            continue
        try:
            mtime = os.lstat(os.path.join(path, name)).st_mtime
        except OSError:
            continue
        newest = mtime if newest is None or mtime > newest else newest
    row["lastCommitAt"] = iso(commit_time)
    created = None
    if branch:
        # When the oldest reflog entry was written, if that entry records the branch's creation; once expiry
        # has removed it, a later entry would claim a creation that is too recent, so the time stays unknown.
        entries = git(path, "log", "-g", "--date=unix", "--format=%gd%x00%gs", f"refs/heads/{branch}", "--",
                      check=False).stdout.splitlines()
        selector, _, subject = entries[-1].partition("\0") if entries else ("", "", "")
        match = re.search(r"@\{(\d+)\}$", selector)
        if match and subject.startswith(CREATED):
            created = int(match.group(1))
    row["branchCreatedAt"] = iso(created)
    row["lastFileChangeAt"] = iso(newest)
    latest = max(t for t in (commit_time, newest, 0) if t is not None)
    row["idleDays"] = int((now - latest) // 86400) if latest else None
    row["stale"] = row["idleDays"] is not None and row["idleDays"] >= stale_days

    remote = info["remote"]
    row["upstream"], row["upstreamGone"] = None, None
    if branch:
        track = git(path, "for-each-ref", "--format=%(upstream:short)%00%(upstream:track)",
                    f"refs/heads/{branch}").stdout.strip()
        upstream, _, state = track.partition("\0")
        row["upstream"] = upstream or None
        if upstream:
            row["upstreamGone"] = state == "[gone]"
            if info["live"] is not None and upstream.startswith(f"{remote}/"):
                row["upstreamGone"] = upstream.removeprefix(f"{remote}/") not in info["live"]
    if info["live"] is not None:
        # Against the live branches, so commits whose remote branch was deleted unmerged count as unpushed.
        # Other remotes were not listed, so their remote-tracking refs stand in for them.
        others = [f"--glob=refs/remotes/{r}/*" for r in info["remotes"] if r != remote]
        count = git(path, "rev-list", "--count", "HEAD", "--not", *info["tips"], *others, check=False)
    else:
        count = git(path, "rev-list", "--count", "HEAD", "--not", "--remotes", check=False)
    row["unpushed"] = int(count.stdout.strip() or 0) if count.returncode == 0 else None

    row["processes"] = processes_in(real, processes)
    return row


def processes_in(real, processes):
    if processes is None:
        return None
    mine = sorted({(pid, comm) for cwd, pid, comm in processes if cwd == real or cwd.startswith(real + "/")})
    return [{"pid": pid, "comm": comm} for pid, comm in mine]


def settle_base(row, remote):
    """Fill `base`, `inBase` and `notInBase` once the pull request (and so its base branch) is known."""
    row["base"], row["inBase"], row["notInBase"] = None, None, None
    if not row["exists"] or row.get("error"):
        return
    pr_base = row["pr"]["base"] if row.get("pr") else None
    base = pick_base(row["path"], remote, pr_base)
    if base is None:
        return
    row["base"] = base
    row["inBase"], row["notInBase"] = containment(row["path"], base)


def lane_of(row):
    """The one thing a worktree is waiting on, with the reasons behind it."""
    if not row["exists"]:
        return "missing", ["registered, but the directory is gone"]
    if row.get("error"):
        reasons = [row["error"]]
        if row["prunable"]:
            reasons.append("Git marks it prunable, yet the directory exists: its .git file may be gone")
        if row["processes"]:
            reasons.append(f"{len(row['processes'])} processes run inside it")
        return "unreadable", reasons
    reasons = []
    pr = row.get("pr")
    changes = row["changes"]
    dirty = changes["modified"] + changes["untracked"] + changes["conflicted"]
    done = row["inBase"] is True or bool(pr and pr["state"] == "merged" and pr["sameHead"])
    if row["processes"]:
        return "in-use", [f"{len(row['processes'])} processes run inside it"]
    if row["kind"] == "tmp" and changes["deleted"]:
        return "damaged", [f"{changes['deleted']} tracked files deleted, likely by tmp ageing"]
    if dirty or changes["deleted"]:
        return "uncommitted", [f"{dirty + changes['deleted']} uncommitted changes"]
    unpushed = [f"{row['unpushed']} commits on no remote branch"] if row["unpushed"] else []
    if not done and pr and pr["state"] == "merged":
        # Often an earlier draft of a reworked PR; the size of `notInBase` says how much never landed.
        return "merged-diverged", [f"PR #{pr['number']} merged, but this head differs and is not in {row['base']}",
                                   *unpushed]
    if unpushed and not done:
        return "unpushed", unpushed
    if pr and pr["state"] == "open":
        return "open-pr", [f"PR #{pr['number']} is open"]
    if not done and pr and pr["state"] == "closed":
        return "closed-pr", [f"PR #{pr['number']} closed without merging"]
    if not done:
        where = "not in " + row["base"] if row["base"] else "no base branch to compare with"
        return "no-pr", [f"{where}, and no PR found" if row["prSource"] == "ok"
                         else f"{where}; PR lookup {row['prSource']}"]
    if row["ignoredOther"]:
        reasons.append(f"{row['ignoredOther']} ignored entries that a build does not recreate")
    if row["submodulesChanged"]:
        reasons.append(f"{row['submodulesChanged']} submodules on other commits")
    if reasons:
        return "check-ignored", reasons
    return "removable", ["clean, and its work is in " + (row["base"] if row["inBase"] else f"merged PR #{pr['number']}"),
                         f"idle {row['idleDays']} days"]


class Forgejo:
    def __init__(self, url, token):
        self.url = url.rstrip("/")
        self.host = urllib.parse.urlparse(self.url).netloc.lower()
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
            raise ForgeError(f"GET {path} returned HTTP {error.code}") from None
        except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as error:
            raise ForgeError(f"GET {path} failed: {error}") from None


def pr_row(number, url, state, base, head_sha, head, updated, merged, matched):
    return {"number": number, "url": url, "state": state, "base": base, "headSha": head_sha,
            "sameHead": head_sha == head, "updatedAt": updated, "mergedAt": merged, "matchedBy": matched}


def match_pr(row, prs):
    """The pull request for a worktree: one whose head is its HEAD, else the newest from its branch.

    Pull requests from a long-lived branch (promotions) never match: their head follows that branch.
    """
    prs = [p for p in prs if p.get("headRef") not in KEPT_BRANCHES]
    by_head = [p for p in prs if p["headSha"] == row["head"]]
    branch = row["branch"]
    by_branch = [p for p in prs if branch and branch not in KEPT_BRANCHES and p.get("headRef") == branch]
    for found, how in ((by_head, "head"), (by_branch, "branch")):
        if found:
            best = max(found, key=lambda p: (p["state"] == "open", p["updatedAt"] or ""))
            return pr_row(best["number"], best["url"], best["state"], best["base"], best["headSha"], row["head"],
                          best["updatedAt"], best["mergedAt"], how)
    return None


def started(row):
    """The earliest a pull request for this row can have been updated: its HEAD commit or branch creation.

    A branch whose creation is unknown (no reflog, or its creation entry expired) could have a pull request of any
    age, so it bounds nothing.
    """
    named = row.get("branch") and row["branch"] not in KEPT_BRANCHES
    if named and not row.get("branchCreatedAt"):
        return 0
    # A long-lived branch never matches by name, so only its commit bounds a head match.
    created = parse_time(row.get("branchCreatedAt")) if named else None
    times = [t for t in (parse_time(row.get("lastCommitAt")), created) if t is not None]
    return min(times) if times else 0


def forgejo_prs(api, name, rows):
    """Recently updated pull requests of a Forgejo repository, enough to match every row.

    A pull request whose head is a worktree's HEAD was updated after that commit, and one from its branch after the
    branch was created here or soon before. Listing goes on until every row has a head match, or a page is older
    than BRANCH_MARGIN before the oldest of those times among the rows still without one.
    """
    found, page = [], 1
    while page <= PR_PAGES:
        batch = api.get(f"/repos/{name}/pulls", {"state": "all", "sort": "recentupdate", "limit": 50, "page": page})
        if not batch:
            break
        for p in batch:
            state = "merged" if p.get("merged") else p.get("state")
            head = p.get("head") or {}
            # Once its branch is deleted, Forgejo points the head ref at refs/pull/N/head; the label keeps the name.
            ref = head.get("ref") or ""
            ref = head.get("label") if ref.startswith("refs/") else ref
            found.append({"number": p["number"], "url": p.get("html_url"), "state": state,
                          "base": (p.get("base") or {}).get("ref"), "headSha": head.get("sha"), "headRef": ref,
                          "updatedAt": p.get("updated_at"), "mergedAt": p.get("merged_at")})
        unmatched = [r for r in rows if (match_pr(r, found) or {}).get("matchedBy") != "head"]
        if not unmatched:
            break
        oldest_wanted = min(started(r) for r in unmatched) - BRANCH_MARGIN
        if min(parse_time(p.get("updated_at")) or 0 for p in batch) < oldest_wanted:
            break
        page += 1
    return found


def gh(*args):
    """Run gh and parse its JSON output; gh keeps its credentials to itself."""
    result = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=120, check=False)
    if result.returncode != 0:
        lines = result.stderr.strip().splitlines()
        raise ForgeError(f"gh {args[0]}: {lines[-1] if lines else 'failed'}")
    return json.loads(result.stdout or "null")


def github_prs(name, row):
    found = []
    try:
        pulls = gh("api", f"repos/{name}/commits/{row['head']}/pulls")
    except ForgeError as error:
        # GitHub answers 422 for a commit it has never seen, which is a normal "no PR".
        if "422" not in str(error) and "No commit found" not in str(error):
            raise
        pulls = []
    for p in pulls or []:
        found.append({"number": p["number"], "url": p.get("html_url"),
                      "state": "merged" if p.get("merged_at") else p.get("state"),
                      "base": (p.get("base") or {}).get("ref"), "headSha": (p.get("head") or {}).get("sha"),
                      "headRef": (p.get("head") or {}).get("ref"), "updatedAt": p.get("updated_at"),
                      "mergedAt": p.get("merged_at")})
    if row["branch"] and row["branch"] not in KEPT_BRANCHES:
        listed = gh("pr", "list", "--repo", name, "--state", "all", "--head", row["branch"], "--limit", "10",
                    "--json", "number,url,state,baseRefName,headRefOid,headRefName,updatedAt,mergedAt")
        for p in listed or []:
            found.append({"number": p["number"], "url": p.get("url"), "state": p["state"].lower(),
                          "base": p.get("baseRefName"), "headSha": p.get("headRefOid"),
                          "headRef": p.get("headRefName"), "updatedAt": p.get("updatedAt"),
                          "mergedAt": p.get("mergedAt")})
    return found


def lookup_prs(rows, infos, forgejo_hosts, api, use_github):
    """Attach `forge`, `pr`, `prSource` and `prError` to each row; returns the per-forge source status."""
    sources = {"forgejo": "skipped" if api is None else "ok", "github": "ok" if use_github else "skipped"}
    groups = {}
    for row in rows:
        row["pr"], row["prSource"], row["prError"] = None, "skipped", None
        info = infos[row["repoPath"]]
        if info["host"] == "github.com":
            row["forge"] = "github"
        elif info["host"] in forgejo_hosts:
            row["forge"] = "forgejo"
        elif info["host"]:
            row["forge"] = "unknown"
        if not row["exists"] or row.get("error") or not row["head"] or row["forge"] not in {"github", "forgejo"}:
            continue
        if (row["forge"] == "forgejo" and api is None) or (row["forge"] == "github" and not use_github):
            continue
        groups.setdefault((row["forge"], info["name"]), []).append(row)

    def forgejo_group(name, members):
        meta = api.get(f"/repos/{name}")
        original = urllib.parse.urlparse(meta.get("original_url") or "") if meta.get("mirror") else None
        if original and original.netloc.lower() == "github.com":
            # Forgejo only mirrors this one; its pull requests live on GitHub.
            mirror = "/".join(original.path.strip("/").removesuffix(".git").split("/")[-2:])
            for row in members:
                row["forge"], row["remoteRepo"] = "github", mirror
            if not use_github:
                return
            for row in members:
                github_row(mirror, row)
            return
        prs = forgejo_prs(api, name, members)
        for row in members:
            row["pr"], row["prSource"] = match_pr(row, prs), "ok"

    def github_row(name, row):
        row["pr"], row["prSource"] = match_pr(row, github_prs(name, row)), "ok"

    def run(key, members):
        forge, name = key
        try:
            if forge == "forgejo":
                forgejo_group(name, members)
            else:
                for row in members:
                    github_row(name, row)
        except (ForgeError, RuntimeError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
            for row in members:
                row["prSource"], row["prError"] = "error", str(error)[:200]

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(lambda item: run(*item), groups.items()))
    errors = {row["forge"] for row in rows if row["prSource"] == "error"}
    for forge in errors & set(sources):
        if sources[forge] == "ok":
            sources[forge] = "partial"
    return sources


def snapshot_of(rows):
    return {r["path"]: {"repo": r["repo"], "branch": r["branch"], "head": r["head"], "lane": r["lane"],
                        "pr": r["pr"]["number"] if r.get("pr") else None,
                        "prState": r["pr"]["state"] if r.get("pr") else None} for r in rows}


def diff_snapshots(previous, current):
    old, new = previous.get("worktrees", {}), current
    added = sorted(set(new) - set(old))
    removed = [{"path": p, **{k: old[p].get(k) for k in ("repo", "branch", "lane")}} for p in sorted(set(old) - set(new))]
    changed = []
    for path in sorted(set(old) & set(new)):
        fields = {k: {"from": old[path].get(k), "to": new[path][k]} for k in ("head", "lane", "pr", "prState")
                  if old[path].get(k) != new[path][k]}
        if fields:
            changed.append({"path": path, **fields})
    return {"added": added, "removed": removed, "changed": changed}


def default_state_file():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, PROG, "last.json")


def save_snapshot(path, generated, rows):
    path = os.path.abspath(path)
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    handle, temp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".last-")
    with os.fdopen(handle, "w", encoding="utf-8") as out:
        json.dump({"generatedAt": generated, "worktrees": snapshot_of(rows)}, out, separators=(",", ":"))
    os.replace(temp, path)


def main(argv=None):
    home = os.path.expanduser("~")
    parser = argparse.ArgumentParser(prog=PROG, description="List Git worktrees with cleanup facts as JSON.")
    parser.add_argument("--root", default=os.path.join(home, "src"), help="source root to search (~/src)")
    parser.add_argument("--worktrees", help="manual worktree root (ROOT/.worktrees)")
    parser.add_argument("--t3-root", action="append", help="T3 worktree root (repeatable; every ~/.t3*/worktrees)")
    parser.add_argument("--tmp-root", action="append", help="temporary root (repeatable; /tmp and /var/tmp)")
    parser.add_argument("--depth", type=int, default=4, help="directory levels below ROOT to search (4)")
    parser.add_argument("--stale-days", type=int, default=14, help="idle days before a worktree is stale (14)")
    parser.add_argument("--fetch", action="store_true", help="fetch each repository and read its live branches")
    parser.add_argument("--no-forge", action="store_true", help="skip pull request lookups")
    parser.add_argument("--no-github", action="store_true", help="skip GitHub lookups")
    parser.add_argument("--state-file", default=default_state_file(), help="snapshot to compare with and --save to")
    parser.add_argument("--save", action="store_true", help="replace the snapshot with this run")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exit_:
        return 0 if exit_.code == 0 else 64
    if not (0 < args.depth < 10 and 0 < args.stale_days < 10000) or not os.path.isdir(args.root):
        print(f"{PROG}: --root must be a directory, --depth 1 to 9 and --stale-days positive", file=sys.stderr)
        return 64

    root = os.path.realpath(args.root)
    worktrees_root = os.path.realpath(args.worktrees or os.path.join(root, ".worktrees"))
    t3_roots = args.t3_root or glob.glob(os.path.join(glob.escape(home), ".t3*", "worktrees"))
    roots = {"worktrees": worktrees_root, "t3": [os.path.realpath(t) for t in t3_roots],
             "tmp": [os.path.realpath(t) for t in (args.tmp_root or ["/tmp", "/var/tmp"])]}
    now = datetime.datetime.now(datetime.timezone.utc)
    generated = now.strftime("%Y-%m-%dT%H:%M:%SZ")

    repos = [{"path": p, "rel": os.path.relpath(p, root)} for p in find_repos(root, args.depth, {worktrees_root})]
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        listed = [(r, entries) for r, entries in pool.map(lambda r: (r, list_worktrees(r["path"])), repos) if entries]
        # Only repositories with linked worktrees are read and fetched.
        infos = dict(zip([r["path"] for r, _ in listed],
                         pool.map(lambda item: remote_info(item[0]["path"], args.fetch), listed)))
        processes = scan_processes()
        jobs = [(repo, entry) for repo, entries in listed for entry in entries]
        rows = list(pool.map(lambda job: inspect(job[1], job[0], infos[job[0]["path"]], roots, processes,
                                                 now.timestamp(), args.stale_days), jobs))
    for (repo, _), row in zip(jobs, rows):
        row["repoPath"] = repo["path"]

    # The token goes only to the Forgejo the Nix wrapper pins; there is no flag to change it.
    url = os.environ.get("WORKTREE_AUDIT_FORGEJO_URL", "https://git.alc.xyz")
    # Remotes on these hosts (the web host and its SSH host) are repositories on that Forgejo.
    forgejo_hosts = {h.strip().lower() for h in os.environ.get("WORKTREE_AUDIT_FORGEJO_REMOTE_HOSTS",
                                                               "git.alc.xyz,git-ssh.alc.xyz").split(",") if h.strip()}
    forgejo_hosts.add(urllib.parse.urlparse(url).hostname)
    api, forgejo_source = None, "skipped"
    if not args.no_forge:
        try:
            with open(os.environ["FORGEJO_API_TOKEN_FILE"], encoding="utf-8") as handle:
                api = Forgejo(url, handle.read().strip())
        except (KeyError, OSError, UnicodeDecodeError):
            forgejo_source = "no token"
    sources = lookup_prs(rows, infos, forgejo_hosts, api, not args.no_forge and not args.no_github)
    if api is None:
        sources["forgejo"] = forgejo_source
    sources["processes"] = "ok" if processes is not None else "unavailable"
    sources["fetch"] = "off" if not args.fetch else (
        "partial" if any(i["fetchError"] for i in infos.values()) else "ok")

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda row: settle_base(row, infos[row["repoPath"]]["remote"]), rows))
    for row in rows:
        row["lane"], row["reasons"] = lane_of(row)
        del row["repoPath"]
    rows.sort(key=lambda r: (LANES.index(r["lane"]), -(r.get("idleDays") or 0), r["path"]))

    previous, changes = None, None
    try:
        with open(args.state_file, encoding="utf-8") as handle:
            old = json.load(handle)
        previous = {"generatedAt": old.get("generatedAt")}
        changes = diff_snapshots(old, snapshot_of(rows))
    except (OSError, ValueError, AttributeError):
        pass
    if args.save:
        save_snapshot(args.state_file, generated, rows)

    count = lambda key: {v: sum(1 for r in rows if r.get(key) == v) for v in sorted({r.get(key) for r in rows})}
    json.dump({
        "generatedAt": generated,
        "root": root,
        "staleDays": args.stale_days,
        "sources": sources,
        "totals": {"repos": len(repos), "worktrees": len(rows), "kinds": count("kind"), "lanes": count("lane"),
                   "stale": sum(1 for r in rows if r.get("stale")), "managed": sum(1 for r in rows if r["managed"])},
        "previous": previous,
        "changes": changes,
        "worktrees": rows,
    }, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
