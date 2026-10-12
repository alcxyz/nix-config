#!/usr/bin/env python3
"""Contract tests for backlog-inventory (ADR-0093), against a fake Forgejo and gh."""

import datetime
import http.server
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "modules/home-manager/programs/ai/backlog-inventory.py"
NOW = datetime.datetime.now(datetime.timezone.utc)
SECRET = "BODY-TEXT-MUST-NOT-LEAK"
HEAD = "abcdef1234567890abcdef1234567890abcdef12"


def ago(days):
    return (NOW - datetime.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def check(condition, message):
    if not condition:
        fail(message)


spec = importlib.util.spec_from_file_location("backlog_inventory", SCRIPT)
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)

# Reference parsing: closing keywords, cross-repo refs, URLs on our host only.
refs = inventory.references(
    "Closes #2, refs other/repo#5 and fixes: https://git.example/me/app/issues/7.\n"
    "See https://elsewhere.example/me/app/issues/8 and foo#9 and v1.2#3", "me/app", "git.example")
check(refs == {("me/app", 2): True, ("other/repo", 5): False, ("me/app", 7): True},
      f"unexpected references: {refs}")
check(inventory.ci_state([]) == "none" and inventory.ci_state(["success", "pending"]) == "pending"
      and inventory.ci_state(["success", "failure"]) == "failure", "ci_state combines badly")
check(inventory.review_state([{"body": f"Automated read-only review ({HEAD[:12]} on dev): full: clean"}], HEAD, "dev")
      == "head", "review at head not found")
check(inventory.review_state([{"body": "Automated read-only review (1111111 on dev): x"}], HEAD, "dev") == "outdated",
      "older review not outdated")
# Like the merge guard, a review on another target branch does not count after a retarget.
check(inventory.review_state([{"body": f"Automated read-only review ({HEAD[:12]} on dev): x"}], HEAD, "main")
      == "outdated", "a review for another target branch counted")
# Issue text is untrusted: an impossible status date is ignored, not fatal.
check(inventory.status_line("**Status (2026-02-31):** Next: x. Owner: me.", NOW) is None, "bad status date accepted")
check(inventory.pr_kind("app/renovate", "me") == "bot" and inventory.pr_kind("dependabot[bot]", "me") == "bot",
      "gh bot authors not recognised")
status = inventory.status_line("**Status (2026-10-01):** Decided: a. Next: do the thing. Owner: me.\n\nRest", NOW)
check(status["owner"] == "me" and status["next"] == "do the thing." and status["date"] == "2026-10-01",
      f"status line parsed badly: {status}")


def issue(number, title, body="", updated=1, created=30, user="me", labels=()):
    return {"number": number, "title": title, "body": body + SECRET, "html_url": f"https://forge/me/app/issues/{number}",
            "user": {"login": user}, "created_at": ago(created), "updated_at": ago(updated), "comments": 0,
            "labels": [{"name": name} for name in labels], "milestone": None, "assignees": None,
            "repository": {"full_name": "me/app"}}


def pull_hit(number, title, body="", merged_days=None):
    return {"number": number, "title": title, "body": body, "html_url": f"https://forge/me/app/pulls/{number}",
            "repository": {"full_name": "me/app"},
            "pull_request": {"merged": merged_days is not None,
                             "merged_at": ago(merged_days) if merged_days is not None else None}}


ISSUES = [
    issue(1, "All boxes ticked", "- [x] one\n- [X] two\n"),
    issue(2, "Closed by a merged PR"),
    issue(3, "Has an open PR"),
    issue(4, "Old and idle", updated=100, created=200),
    issue(5, "Has a status line", "**Status (2026-10-01):** Decided: a. Next: do the thing. Owner: me.\n\n- [x] a\n- [ ] b\n"),
    issue(6, "Mentioned by a merged PR, untouched since", updated=10),
    issue(8, "Mentioned by a PR merged yesterday", updated=10),
    issue(9, "Has a malformed status date", "**Status (2026-02-30):** Next: x. Owner: me.\n"),
    issue(7, "Dependency Dashboard", user="renovate"),
    {**issue(1, "Archived repo issue"), "repository": {"full_name": "me/old"}},
]
MERGED = [pull_hit(20, "fix: two", f"Closes #2\n{SECRET}", merged_days=2),
          pull_hit(21, "feat: part", "Part of me/app#6", merged_days=5),
          pull_hit(23, "feat: more", "Part of #8", merged_days=1),
          pull_hit(22, "closed unmerged", "Closes #5")]
OPEN = [pull_hit(n, t, b) for n, t, b in [
    (30, "held by a thread", "Refs #3"), (31, "reviewed earlier", ""), (32, "conflicting", ""),
    (33, "chore(deps): bump", ""), (34, "ready one", ""), (35, "draft, reported unmergeable", ""),
    (36, "reviewed for another branch", "")]]
PULLS = {
    30: dict(user="me", mergeable=True), 31: dict(user="me", mergeable=True), 32: dict(user="me", mergeable=False),
    33: dict(user="renovate", mergeable=True), 34: dict(user="me", mergeable=True),
    35: dict(user="me", mergeable=False, draft=True), 36: dict(user="me", mergeable=True, base="main"),
}
COMMENTS = {30: [], 31: [{"body": "Automated read-only review (1234567 on dev): full: clean"}], 32: [],
            34: [{"body": f"Automated read-only review ({HEAD[:12]} on dev): full: clean"}], 35: [],
            36: [{"body": f"Automated read-only review ({HEAD[:12]} on dev): full: clean"}]}


class Forge(http.server.BaseHTTPRequestHandler):
    seen_auth = set()
    redirect = False

    def log_message(self, *args):
        pass

    def reply(self, body, code=200):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        Forge.seen_auth.add(self.headers.get("Authorization"))
        url = urllib.parse.urlparse(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        path = url.path.removeprefix("/api/v1")
        if Forge.redirect:
            self.send_response(302)
            self.send_header("Location", "http://elsewhere.invalid/")
            self.end_headers()
            return
        if query.get("page", "1") != "1":
            return self.reply([])
        if path == "/user":
            return self.reply({"login": "me"})
        if path == "/user/repos":
            return self.reply([
                {"full_name": "me/app", "html_url": "https://forge/me/app", "archived": False, "mirror": False,
                 "updated_at": ago(0), "original_url": ""},
                {"full_name": "me/old", "html_url": "https://forge/me/old", "archived": True, "mirror": False,
                 "updated_at": ago(0), "original_url": ""},
                {"full_name": "me/ghrepo", "html_url": "https://forge/me/ghrepo", "archived": False, "mirror": True,
                 "updated_at": ago(0), "original_url": "https://github.com/me/ghrepo.git"},
            ])
        if path == "/repos/issues/search":
            if query["type"] == "issues":
                return self.reply(ISSUES)
            return self.reply(MERGED if query["state"] == "closed" else OPEN)
        parts = path.strip("/").split("/")
        if parts[:3] == ["repos", "me", "app"] and parts[3] == "pulls":
            number = int(parts[4])
            pull = PULLS[number]
            hit = next(p for p in OPEN if p["number"] == number)
            return self.reply({"number": number, "title": hit["title"], "body": hit["body"] + "\n" + SECRET,
                               "html_url": f"https://forge/me/app/pulls/{number}",
                               "user": {"login": pull["user"]}, "draft": pull.get("draft", False),
                               "mergeable": pull["mergeable"], "base": {"ref": pull.get("base", "dev")},
                               "head": {"sha": HEAD},
                               "created_at": ago(3), "updated_at": ago(1)})
        if parts[:4] == ["repos", "me", "app", "commits"]:
            return self.reply({"state": "success", "statuses": [{"status": "success"}]})
        if parts[:4] == ["repos", "me", "app", "issues"] and parts[5] == "comments":
            return self.reply(COMMENTS[int(parts[4])])
        self.reply({"message": "not found"}, 404)


FAKE_GH = r'''
import json, os, sys
args = sys.argv[1:]
if os.environ.get("FAKE_GH_FAIL"):
    print("gh: not logged in", file=sys.stderr)
    sys.exit(1)
now = os.environ["FAKE_NOW"]
def out(value):
    print(json.dumps(value))
    sys.exit(0)
joined = " ".join(args)
if args[:2] == ["api", "user"]:
    out({"login": "me"})
if args[:2] == ["api", "repos/me/ghrepo"]:
    out({"html_url": "https://github.com/me/ghrepo", "pushed_at": now, "archived": False, "fork": False})
if "repos/me/ghrepo/issues?state=open" in joined:
    out([[{"number": 1, "title": "GitHub issue", "body": "- [x] done BODY-TEXT-MUST-NOT-LEAK",
           "html_url": "https://github.com/me/ghrepo/issues/1", "user": {"login": "me"},
           "created_at": now, "updated_at": now, "comments": 0, "labels": [], "milestone": None, "assignees": []},
          {"number": 2, "title": "a PR", "pull_request": {}}]])
if "repos/me/ghrepo/pulls?state=closed" in joined:
    # One merge outside the --merged-days window, which must not count.
    out([{"number": 3, "title": "old", "body": "Closes #1", "html_url": "https://github.com/me/ghrepo/pull/3",
          "merged_at": "2020-01-01T00:00:00Z", "updated_at": "2020-01-01T00:00:00Z"}])
if "issues/2/comments" in joined:
    out([[]])
if args[:2] == ["search", "prs"]:
    out([{"repository": {"nameWithOwner": "up/stream"}, "number": 9},
         {"repository": {"nameWithOwner": "me/ghrepo"}, "number": 2}])
if args[:2] == ["pr", "view"]:
    number = int(args[2])
    out({"number": number, "title": f"PR {number}", "body": "Fixes #1" if number == 2 else "",
         "url": f"https://github.com/{args[4]}/pull/{number}", "author": {"login": "me"}, "isDraft": False,
         "reviewDecision": "APPROVED" if number == 9 else None, "baseRefName": "main", "headRefOid": "f" * 40,
         "mergeable": "MERGEABLE", "statusCheckRollup": [{"conclusion": "SUCCESS"}],
         "createdAt": now, "updatedAt": now})
print("unexpected gh call: " + joined, file=sys.stderr)
sys.exit(2)
'''


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Forge)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        token = tmp / "token"
        token.write_text("test-token\n")
        bindir = tmp / "bin"
        bindir.mkdir()
        (bindir / "gh").write_text(f"#!{sys.executable}\n{FAKE_GH}")
        (bindir / "gh").chmod(0o755)
        threads = tmp / "threads.json"
        threads.write_text(json.dumps({"threads": [
            {"threadId": "t-live", "title": "Live thread", "bucket": "unsettled", "status": "idle",
             "prs": [{"url": "https://forge/me/app/pulls/30", "state": "open"}]},
            {"threadId": "t-old", "title": "Settled thread", "bucket": "recently-settled", "status": "idle",
             "prs": [{"url": "https://forge/me/app/pulls/32", "state": "open"}]}]}))
        env = {**os.environ, "PATH": f"{bindir}:{os.environ['PATH']}", "FORGEJO_API_TOKEN_FILE": str(token),
               "BACKLOG_FORGEJO_URL": base, "FAKE_NOW": ago(0)}

        def run(*args, extra=None):
            return subprocess.run([sys.executable, "-I", str(SCRIPT), *args],
                                  capture_output=True, text=True, env={**env, **(extra or {})}, check=False)

        result = run("--threads", str(threads))
        check(result.returncode == 0, f"inventory failed: {result.stderr}")
        check(SECRET not in result.stdout, "an issue or PR body reached the output")
        check(Forge.seen_auth == {"token test-token"}, f"unexpected Authorization headers: {Forge.seen_auth}")
        report = json.loads(result.stdout)
        check(report["sources"] == {"forgejo": base, "github": "ok", "threads": "ok"}, f"sources: {report['sources']}")

        issues = {i["ref"]: i for i in report["issues"]}
        lanes = {ref: i["lane"] for ref, i in issues.items()}
        check(lanes == {"me/app#1": "close", "me/app#2": "close", "me/app#3": "inflight", "me/app#4": "stale",
                        "me/app#5": "active", "me/app#6": "active", "me/app#7": "dashboard", "me/app#8": "active",
                        "me/app#9": "active", "gh:me/ghrepo#1": "close"},
              f"issue lanes: {lanes}")
        check("me/old#1" not in issues, "an archived repository's issue was listed")
        check(issues["me/app#2"]["mergedPrs"][0]["closes"] is True, "closing keyword not recorded")
        check(issues["me/app#5"]["status"]["owner"] == "me" and issues["me/app#5"]["checks"] == {"done": 1, "total": 2},
              f"status or checks: {issues['me/app#5']}")
        check("partly-done" in issues["me/app#5"]["flags"], "partly-done flag missing")
        check({"mentioned-by-merged-pr", "untouched-since-merge"} <= set(issues["me/app#6"]["flags"]),
              f"merged mention flags: {issues['me/app#6']['flags']}")
        check(issues["me/app#3"]["openPrs"] == ["me/app#30"], "open PR reference missing")
        check("untouched-since-merge" not in issues["me/app#8"]["flags"], "flagged before three days since the merge")
        check(issues["me/app#9"]["status"] is None, "a malformed status date was kept")
        check(issues["gh:me/ghrepo#1"]["mergedPrs"] == [], "a merge outside --merged-days was joined")

        prs = {p["ref"]: p for p in report["prs"]}
        pr_lanes = {ref: p["lane"] for ref, p in prs.items()}
        check(pr_lanes == {"me/app#30": "inflight", "me/app#31": "open", "me/app#32": "blocked", "me/app#33": "renovate",
                           "me/app#34": "ready", "me/app#35": "open", "me/app#36": "open",
                           "gh:me/ghrepo#2": "open", "gh:up/stream#9": "ready"},
              f"PR lanes: {pr_lanes}")
        check(prs["me/app#30"]["thread"]["threadId"] == "t-live", "thread not joined")
        check("conflict" not in prs["me/app#35"]["flags"], "a draft was called conflicting")
        check(prs["me/app#36"]["review"] == "outdated", "a review for another target branch counted")
        check({"review-outdated", "orphan"} <= set(prs["me/app#31"]["flags"]), f"flags: {prs['me/app#31']['flags']}")
        check({"conflict", "thread-settled", "orphan"} <= set(prs["me/app#32"]["flags"]), f"flags: {prs['me/app#32']['flags']}")
        check(prs["gh:me/ghrepo#2"]["issues"] == ["gh:me/ghrepo#1"] and prs["gh:me/ghrepo#2"]["review"] == "none",
              f"GitHub PR: {prs['gh:me/ghrepo#2']}")
        check(prs["gh:up/stream#9"]["kind"] == "upstream" and prs["gh:up/stream#9"]["reviewDecision"] == "approved",
              f"upstream PR: {prs['gh:up/stream#9']}")
        repos = [(r["forge"], r["repo"]) for r in report["repos"]]
        check(repos[0] == ("forgejo", "me/app") and ("github", "up/stream") in repos, f"repos: {repos}")
        check(report["totals"]["issues"] == 10 and report["totals"]["prs"] == 9, f"totals: {report['totals']}")

        # Without --threads nothing is called orphaned; a gh failure only marks GitHub.
        result = run(extra={"FAKE_GH_FAIL": "1"})
        check(result.returncode == 0, f"a gh failure failed the run: {result.stderr}")
        report = json.loads(result.stdout)
        check(report["sources"]["github"].startswith("error: gh api"), f"github source: {report['sources']['github']}")
        check(all("orphan" not in p["flags"] for p in report["prs"]), "orphan flagged without thread data")
        check(all(p["forge"] == "forgejo" for p in report["prs"]), "GitHub rows despite the failure")

        check(run("--no-github", extra={"FORGEJO_API_TOKEN_FILE": str(tmp / "missing")}).returncode == 2,
              "a missing token file did not exit 2")
        check(run("--no-github", extra={"FORGEJO_API_TOKEN_FILE": str(tmp)}).returncode == 2,
              "an unreadable token file did not exit 2")
        check(run("--forgejo-url", "http://elsewhere.invalid").returncode == 64, "the Forgejo URL can be overridden")
        check(run("--stale-days", "0").returncode == 64, "a bad --stale-days did not exit 64")
        Forge.redirect = True
        result = run("--no-github")
        check(result.returncode == 3 and "302" in result.stderr, f"a redirect was followed: {result.returncode} {result.stderr}")
    server.shutdown()
    print("backlog-inventory contract tests passed")


if __name__ == "__main__":
    main()
