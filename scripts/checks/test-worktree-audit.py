#!/usr/bin/env python3
"""Contract tests for worktree-audit (ADR-0093), against fixture repositories."""

import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
# Process discovery reads /proc, which macOS lacks.
PROC = os.path.isdir("/proc")
SCRIPT = ROOT / "modules/home-manager/programs/ai/worktree-audit.py"


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def check(condition, message):
    if not condition:
        fail(message)


spec = importlib.util.spec_from_file_location("worktree_audit", SCRIPT)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

# Remote URLs: the forge identity, never the credentials.
check(audit.parse_remote("git@git-ssh.example.org:owner/repo.git") == ("git-ssh.example.org", "owner/repo"), "scp remote")
check(audit.parse_remote("ssh://git@host.example:2222/owner/repo.git") == ("host.example", "owner/repo"), "ssh remote")
check(audit.parse_remote("https://user:secret@github.com/owner/repo") == ("github.com", "owner/repo"), "https remote")
check(audit.parse_remote("/srv/git/repo.git") == (None, None), "a local path has no forge")

# Pull request matching: head commit first, then branch; promotions never match.
HEAD = "a" * 40
row = {"head": HEAD, "branch": "feat/x", "lastCommitAt": "2026-10-01T00:00:00Z"}
prs = [
    {"number": 1, "url": "u1", "state": "merged", "base": "main", "headSha": HEAD, "headRef": "dev",
     "updatedAt": "2026-10-09T00:00:00Z", "mergedAt": "2026-10-09T00:00:00Z"},
    {"number": 2, "url": "u2", "state": "merged", "base": "dev", "headSha": "b" * 40, "headRef": "feat/x",
     "updatedAt": "2026-10-05T00:00:00Z", "mergedAt": "2026-10-05T00:00:00Z"},
]
match = audit.match_pr(row, prs)
check(match and match["number"] == 2 and match["matchedBy"] == "branch" and not match["sameHead"],
      f"a promotion PR must not match, the branch PR must: {match}")
prs.append({"number": 3, "url": "u3", "state": "open", "base": "dev", "headSha": HEAD, "headRef": "refs-gone",
            "updatedAt": "2026-10-06T00:00:00Z", "mergedAt": None})
match = audit.match_pr(row, prs)
check(match["number"] == 3 and match["matchedBy"] == "head" and match["sameHead"], f"head match wins: {match}")
check(audit.match_pr({**row, "branch": "dev", "head": "c" * 40}, prs) is None, "dev never matches by name")


class Pages:
    """A Forgejo stub that serves pull request pages, newest first, and counts requests."""

    def __init__(self, pages):
        self.pages, self.calls = pages, 0

    def get(self, path, params=None):
        self.calls += 1
        index = params["page"] - 1
        return self.pages[index] if index < len(self.pages) else []


def pull(number, sha, ref, updated, label=None, merged=True):
    return {"number": number, "html_url": f"u{number}", "state": "closed", "merged": merged,
            "merged_at": updated if merged else None, "updated_at": updated, "base": {"ref": "dev"},
            "head": {"sha": sha, "ref": ref, "label": label or ref}}


# A deleted branch leaves refs/pull/N/head as the ref; the label keeps the branch name.
api = Pages([[pull(9, "d" * 40, "refs/pull/9/head", "2026-10-10T00:00:00Z", label="feat/x")]])
found = audit.forgejo_prs(api, "o/r", [row])
check(audit.match_pr(row, found)["number"] == 9, "a deleted branch still matches by its label")
# Listing stops once a page is older than the oldest unmatched commit.
old = [pull(n, "e" * 40, f"other-{n}", "2026-08-15T00:00:00Z") for n in range(50)]
api = Pages([old, old, old])
audit.forgejo_prs(api, "o/r", [{**row, "branch": "feat/none", "branchCreatedAt": "2026-09-30T00:00:00Z"}])
check(api.calls == 1, f"paging must stop at old pull requests, made {api.calls} calls")

# A head match on a later page beats a branch match on the first.
api = Pages([[pull(20, "f" * 40, "feat/x", "2026-10-12T00:00:00Z", merged=False)],
             [pull(21, HEAD, "refs/pull/21/head", "2026-10-02T00:00:00Z", label="feat/x")]])
found = audit.forgejo_prs(api, "o/r", [row])
check(audit.match_pr(row, found)["number"] == 21, "paging must go on past a branch match to find the head match")
# Commits added long after a PR merged: the branch's creation, not its last commit, bounds the search.
late = {**row, "head": "9" * 40, "lastCommitAt": "2026-10-10T00:00:00Z", "branchCreatedAt": "2026-08-01T00:00:00Z"}
api = Pages([old, [pull(22, "8" * 40, "feat/x", "2026-08-03T00:00:00Z")]])
found = audit.forgejo_prs(api, "o/r", [late])
check(audit.match_pr(late, found)["number"] == 22, "a branch PR older than the last commit must still be found")
check(audit.started({"head": HEAD}) == 0, "a row without times searches every page")
roots = {"worktrees": "/src/.worktrees", "t3": [], "tmp": ["/tmp"]}
check(audit.kind_of("/src/.worktrees/r/task/.claude/worktrees/s", roots) == "claude", "Claude inside a manual worktree")
kept_row = {**row, "branch": "dev", "branchCreatedAt": "2026-01-01T00:00:00Z"}
check(audit.started(kept_row) == audit.parse_time(row["lastCommitAt"]), "a long-lived branch bounds by its commit")
check(audit.started(row) == 0, "a branch without a reflog entry searches every page")
check(audit.started({**row, "branch": "dev"}) > 0, "a long-lived branch never matches by name, so it bounds by commit")



class Repo(Pages):
    """Pages, plus the repository lookup that comes first."""

    def get(self, path, params=None):
        return {"mirror": False} if params is None else super().get(path, params)


# An unreadable row in a repository must not cost the other rows their PRs.
api = Repo([[pull(30, "7" * 40, "feat/y", "2026-10-12T00:00:00Z", merged=False)], old])
api.host = "forge.example"
good = {"path": "/good", "repoPath": "/repo", "exists": True, "head": "7" * 40, "branch": "feat/y",
        "lastCommitAt": "2026-10-11T00:00:00Z"}
broken = {"path": "/broken", "repoPath": "/repo", "exists": True, "head": "6" * 40, "branch": None,
          "error": "git status: not a git repository"}
infos = {"/repo": {"host": "forge.example", "name": "o/r"}}
audit.lookup_prs([good, broken], infos, {"forge.example"}, api, False)
check(good["prSource"] == "ok" and good["pr"]["number"] == 30, f"good row: {good['prSource']} {good['prError']}")
check(broken["prSource"] == "skipped", f"an unreadable row is not looked up: {broken['prSource']}")

# Without /proc (macOS) processes are unknown, not absent.
real_isdir = audit.os.path.isdir
audit.os.path.isdir = lambda path: False if path == "/proc" else real_isdir(path)
check(audit.scan_processes() is None and audit.processes_in("/x", None) is None, "no /proc means unknown processes")
audit.os.path.isdir = real_isdir

# A bare snapshot file name saves into the current directory.
with tempfile.TemporaryDirectory() as scratch:
    here = os.getcwd()
    os.chdir(scratch)
    try:
        audit.save_snapshot("last.json", "2026-10-16T00:00:00Z", [])
        check(os.path.exists(os.path.join(scratch, "last.json")), "a bare --state-file name is saved")
    finally:
        os.chdir(here)

# Snapshots report what was added, removed and changed.
diff = audit.diff_snapshots(
    {"worktrees": {"/a": {"repo": "r", "branch": "x", "head": "1", "lane": "open-pr", "pr": 4, "prState": "open"},
                   "/b": {"repo": "r", "branch": "y", "head": "2", "lane": "no-pr", "pr": None, "prState": None}}},
    {"/a": {"repo": "r", "branch": "x", "head": "1", "lane": "removable", "pr": 4, "prState": "merged"},
     "/c": {"repo": "r", "branch": "z", "head": "3", "lane": "no-pr", "pr": None, "prState": None}})
check(diff["added"] == ["/c"] and [r["path"] for r in diff["removed"]] == ["/b"], f"added/removed: {diff}")
check(diff["changed"] == [{"path": "/a", "lane": {"from": "open-pr", "to": "removable"},
                           "prState": {"from": "open", "to": "merged"}}], f"changed: {diff['changed']}")

# Fixture repositories, with an isolated Git configuration.
work = pathlib.Path(tempfile.mkdtemp(prefix="worktree-audit-test."))
env = {**os.environ, "HOME": str(work / "home"), "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
       "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid", "GIT_COMMITTER_NAME": "Test",
       "GIT_COMMITTER_EMAIL": "test@example.invalid", "XDG_STATE_HOME": str(work / "state")}
os.makedirs(env["HOME"])
sleeper = None


def git(cwd, *args):
    result = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, env=env, check=False)
    if result.returncode != 0:
        fail(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout.strip()


def commit(cwd, name, text, message):
    (cwd / name).parent.mkdir(parents=True, exist_ok=True)
    (cwd / name).write_text(text)
    git(cwd, "add", "-A")
    git(cwd, "commit", "-q", "-m", message)


def run_audit(*args):
    result = subprocess.run([sys.executable, "-I", str(SCRIPT), "--root", str(src), "--tmp-root", str(tmp),
                             "--t3-root", str(work / "t3"), "--no-forge", *args],
                            capture_output=True, text=True, env=env, check=False)
    check(result.returncode == 0, f"worktree-audit exited {result.returncode}: {result.stderr}")
    return json.loads(result.stdout)


try:
    src, tmp, trees = work / "src", work / "tmp", work / "src" / ".worktrees" / "proj"
    for path in (src, tmp, trees):
        path.mkdir(parents=True)
    origin, main = work / "origin.git", src / "proj"
    git(work, "init", "-q", "--bare", "-b", "dev", str(origin))
    git(work, "clone", "-q", str(origin), str(main))
    git(main, "checkout", "-q", "-b", "dev")
    commit(main, "README.md", "proj\n", "init")
    commit(main, ".gitignore", "notes.local\nnode_modules/\n", "ignore")
    git(main, "push", "-q", "-u", "origin", "dev")

    def worktree(name, base="origin/dev", where=None):
        path = (where or trees) / name
        git(main, "worktree", "add", "-q", "-b", name, str(path), base)
        return path

    # Squash-merged into dev: clean and removable, even with a rebuildable ignored directory.
    merged = worktree("merged")
    commit(merged, "feature.txt", "feature\n", "feature")
    git(merged, "push", "-q", "-u", "origin", "merged")
    (merged / "node_modules").mkdir()
    (merged / "node_modules" / "x.js").write_text("x")
    # Merged too, but holding an ignored file a build does not recreate.
    kept = worktree("kept")
    commit(kept, "kept.txt", "kept\n", "kept")
    git(kept, "push", "-q", "-u", "origin", "kept")
    (kept / "notes.local").write_text("notes")
    commit(main, "feature.txt", "feature\n", "squash of merged")
    commit(main, "kept.txt", "kept\n", "squash of kept")
    git(main, "push", "-q", "origin", "dev")

    dirty = worktree("dirty")
    (dirty / "draft.txt").write_text("draft")
    local = worktree("local")
    commit(local, "local.txt", "local\n", "local only")
    # A Latin-1 commit message puts non-UTF-8 bytes into the reflog; the row must still be read.
    (work / "msg").write_bytes(b"Rettet f\xf8r\n")
    (local / "latin.txt").write_text("x")
    git(local, "add", "latin.txt")
    git(local, "-c", "i18n.commitEncoding=latin1", "commit", "-q", "-F", str(work / "msg"))
    pushed = worktree("pushed")
    commit(pushed, "pushed.txt", "pushed\n", "pushed")
    git(pushed, "push", "-q", "-u", "origin", "pushed")
    aged = worktree("aged", where=tmp)
    (aged / "README.md").unlink()
    busy = worktree("busy")
    gone = worktree("gone")
    shutil.rmtree(gone)
    # Its .git file is gone but its files remain: unreadable, never "missing".
    broken = worktree("broken")
    (broken / "work.txt").write_text("work")
    (broken / ".git").unlink()
    # The same inside the main checkout: Git must not read it as the checkout around it.
    nested = worktree("nested", where=main / ".claude" / "worktrees")
    (nested / "work.txt").write_text("work")
    (nested / ".git").unlink()
    sleeper = subprocess.Popen(["sleep", "60"], cwd=busy)

    report = run_audit("--save")
    rows = {pathlib.Path(r["path"]).name: r for r in report["worktrees"]}
    expected = {"merged": "removable", "kept": "check-ignored", "dirty": "uncommitted", "local": "unpushed",
                "pushed": "no-pr", "aged": "damaged", "busy": "in-use" if PROC else "removable", "gone": "missing", "broken": "unreadable",
                "nested": "unreadable"}
    for name, lane in expected.items():
        check(name in rows, f"{name} is missing from the report")
        check(rows[name]["lane"] == lane, f"{name}: lane {rows[name]['lane']} ({rows[name]['reasons']}), want {lane}")
    check("proj" not in rows, "the main checkout is not a linked worktree")
    check(rows["merged"]["inBase"] is True and rows["merged"]["ignoredOther"] == 0, f"merged: {rows['merged']}")
    check(rows["kept"]["ignoredSample"] == ["notes.local"], f"kept: {rows['kept']['ignoredSample']}")
    check(rows["pushed"]["notInBase"] == {"conflicts": False, "files": 1, "added": 1, "removed": 0},
          f"pushed: {rows['pushed']['notInBase']}")
    check(rows["local"]["unpushed"] == 2 and rows["pushed"]["unpushed"] == 0, "unpushed counts")
    check(rows["aged"]["kind"] == "tmp" and rows["merged"]["kind"] == "manual", "kinds")
    if PROC:
        check(rows["busy"]["processes"][0]["comm"] == "sleep", f"busy: {rows['busy']['processes']}")
    check(rows["broken"]["exists"] is True and rows["gone"]["exists"] is False, "broken keeps its files, gone does not")
    check(rows["nested"]["kind"] == "claude" and "gone" in rows["nested"]["reasons"][0], f"nested: {rows['nested']}")
    check(rows["merged"]["branchCreatedAt"] is not None, "a branch made here has a creation time")
    # Once expiry removed the creation entry, the oldest surviving one does not count as creation.
    git(main, "reflog", "expire", "--expire=all", "refs/heads/local")
    git(local, "commit", "-q", "--allow-empty", "-m", "after expiry")
    check(report["previous"] is None and report["changes"] is None, "no snapshot before the first save")
    check(report["sources"] == {"forgejo": "skipped", "github": "skipped", "processes": "ok" if PROC else "unavailable",
                                  "fetch": "off"},
          f"{report['sources']}")
    check(report["totals"]["worktrees"] == len(expected), f"totals: {report['totals']}")
    lanes = [r["lane"] for r in report["worktrees"]]
    check(lanes == sorted(lanes, key=audit.LANES.index), f"rows come in lane order: {lanes}")
    status_before = (main / ".git" / "worktrees" / "merged" / "index").stat().st_mtime_ns

    # A second run reports changes against the saved snapshot.
    sleeper.kill()
    sleeper.wait()
    sleeper = None
    (dirty / "draft.txt").unlink()
    worktree("fresh")
    report = run_audit()
    changes = report["changes"]
    check(changes["added"] == [str(trees / "fresh")], f"added: {changes['added']}")
    changed = {pathlib.Path(c["path"]).name: c for c in changes["changed"]}
    if PROC:
        check(changed["busy"]["lane"] == {"from": "in-use", "to": "removable"}, f"busy: {changed.get('busy')}")
    check(changed["dirty"]["lane"] == {"from": "uncommitted", "to": "removable"}, f"dirty: {changed.get('dirty')}")
    rows = {pathlib.Path(r["path"]).name: r for r in report["worktrees"]}
    check(rows["local"]["branchCreatedAt"] is None, f"expired creation entry: {rows['local']['branchCreatedAt']}")
    check(report["previous"]["generatedAt"], "the previous run is named")
    check((main / ".git" / "worktrees" / "merged" / "index").stat().st_mtime_ns == status_before,
          "reading a worktree must not rewrite its index")

    # Fetching counts commits against the live branches: a deleted remote branch makes them unpushed again.
    # It never prunes, even when the repository asks fetch to.
    other = work / "other"
    git(work, "clone", "-q", str(origin), str(other))
    git(other, "push", "-q", "origin", "--delete", "pushed")
    git(main, "config", "fetch.prune", "true")
    report = run_audit("--fetch")
    rows = {pathlib.Path(r["path"]).name: r for r in report["worktrees"]}
    check(report["sources"]["fetch"] == "ok", f"fetch: {report['sources']}")
    check(rows["pushed"]["upstreamGone"] is True and rows["pushed"]["lane"] == "unpushed",
          f"pushed after deletion: {rows['pushed']['lane']}, gone={rows['pushed']['upstreamGone']}")
    check(git(main, "for-each-ref", "refs/remotes/origin/pushed"), "--fetch must not prune remote-tracking refs")
    check(git(main, "worktree", "list", "--porcelain").count("worktree ") == len(expected) + 2,
          "the audit must not remove or prune worktrees")
finally:
    if sleeper is not None:
        sleeper.kill()
    shutil.rmtree(work, ignore_errors=True)

print("worktree-audit: all checks passed")
