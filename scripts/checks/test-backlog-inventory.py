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
# A known repository's bare name before #N is that repository's, also as a Markdown link's text; a
# name several owners share resolves to the source owner's, and "word#N" with an unknown word is no ref.
NAMES = inventory.repo_names(["me/app", "me/lib", "other/lib", "other/tool", "third/tool", "me/old"])
refs = inventory.references(
    "Picks up lib #3 (see [tool #4](https://git.example/other/tool/pulls/4)), fixes old#5,\n"
    "Fixes tool #6, refs app#7, follow-up #8, nosuch#9 and Closes [#10](https://git.example/me/app/issues/10).",
    "me/app", "git.example", NAMES)
check(refs == {("me/lib", 3): False, ("me/old", 5): True, ("me/app", 7): False, ("me/app", 8): False,
               ("me/app", 10): True}, f"unexpected references with repository names: {refs}")
check(inventory.references("tool #6", "me/app", "git.example", NAMES) == {}, "an ambiguous name was resolved")
check(inventory.references('lib  #3, Closes [#10](https://git.example/other/lib/issues/10 "Details")\n'
                           "and [#11](https://git.example/other/lib/issues/11 (x))", "me/app", "git.example", NAMES) == {("me/lib", 3): False, ("other/lib", 10): True, ("other/lib", 11): False},
      "spaces before #N or a Markdown link title broke name matching")
# Names that differ only in case, as between a GitHub repository and its Forgejo mirror, are one repository.
check(inventory.references("foo #3", "me/app", "git.example", inventory.repo_names(["me/Foo", "me/foo"]))
      == {("me/Foo", 3): False}, "a case-only duplicate made a name ambiguous")
check(inventory.references("lib #3", "third/x", "git.example", inventory.repo_names(["other/lib"]))
      == {("other/lib", 3): False}, "a unique name of another owner was not resolved")
check(inventory.references("#3 and app #4", None, "git.example", NAMES) == {("me/app", 4): False},
      "a plain ref without a source repository was kept")
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
inventory.OWN.update({"app/hugin", "hugin[bot]"})
check(inventory.pr_kind("app/hugin", "me") == "own" and not inventory.is_bot("hugin[bot]")
      and inventory.is_bot("app/renovate"), "--own authors still counted as bots")
inventory.OWN.clear()
status = inventory.status_line("**Status (2026-10-01):** Decided: a. Next: do the thing. Owner: me.\n\nRest", NOW)
check(status["owner"] == "me" and status["next"] == "do the thing." and status["date"] == "2026-10-01",
      f"status line parsed badly: {status}")

# Links to other repositories on either forge; same-repository refs, other hosts and dot-only paths are not links.
found = inventory.links(
    "See https://git.example/other/lib/pulls/3, https://github.com/example-org/service/issues/4,\n"
    "https://github.com/example-org/service/pull/5, example-org/api#6, #7, me/app#8, ../..#9,\n"
    "https://elsewhere.example/x/y/issues/1 and https://git.example/me/app/issues/2", "forgejo", "me/app", "git.example")
check(found == {("forgejo", "other/lib", 3), ("github", "example-org/service", 4), ("github", "example-org/service", 5),
                ("forgejo", "example-org/api", 6)}, f"unexpected links: {found}")
check(inventory.links("example-org/api#6", "github", "me/x", "git.example") == {("github", "example-org/api", 6)},
      "a short ref did not stay on the source's forge")

# Scopes: none means all and every group; groups and repositories add up; unknown names are refused.
GROUPS = {"work": {"description": "made-up", "repos": ["gh:example-org/service", "example-org/forge-side"]},
          "tools": {"repos": ["gh:example-org/cli"]}}
scope = inventory.parse_scope([], GROUPS)
check(scope["all"] and scope["groups"] == ["tools", "work"]
      and scope["github"] == {"example-org/service", "example-org/cli"} and scope["forgejo"] == {"example-org/forge-side"},
      f"default scope: {scope}")
scope = inventory.parse_scope(["work", "me/app", "gh:me/ghrepo"], GROUPS)
check(not scope["all"] and scope["groups"] == ["work"] and scope["repos"] == ["me/app", "gh:me/ghrepo"]
      and scope["forgejo"] == {"example-org/forge-side", "me/app"} and scope["github"] == {"example-org/service", "me/ghrepo"},
      f"selected scope: {scope}")
for bad in (["nosuchgroup"], ["gh:no-slash"], ["a/b/c"]):
    try:
        inventory.parse_scope(bad, GROUPS)
        fail(f"scope {bad} accepted")
    except inventory.Fail as error:
        check(error.code == 64, f"scope {bad} exit {error.code}")


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
    issue(4, "Old and idle", "Waits on https://github.com/up/stream/issues/4, other/lib#2, gone/repo#1, me/old#99,\n"
          "the push mirror's https://github.com/me/old/issues/3,\n"
          "the upstream PR https://github.com/up/stream/pull/9 and me/app#5.\n", updated=100, created=200),
    issue(5, "Has a status line", "**Status (2026-10-01):** Decided: a. Next: do the thing. Owner: me.\n\n- [x] a\n- [ ] b\n"),
    issue(6, "Mentioned by a merged PR, untouched since", updated=10),
    issue(8, "Mentioned by a PR merged yesterday", updated=10),
    issue(9, "Has a malformed status date", "**Status (2026-02-30):** Next: x. Owner: me.\n\n"
          "Needs other/lib#2, which closed, and other/tool#3, which is open.\n"),
    issue(7, "Dependency Dashboard", user="renovate"),
    {**issue(1, "Archived repo issue"), "repository": {"full_name": "me/old"}},
]
MERGED = [pull_hit(20, "fix: two", f"Closes #2\n{SECRET}", merged_days=2),
          pull_hit(21, "feat: part", "Part of me/app#6", merged_days=5),
          pull_hit(23, "feat: more", "Part of #8", merged_days=1),
          # Mentions of other repositories' items, by name and in Markdown link text, are not me/app's.
          pull_hit(24, "chore: bump lib", "Picks up lib #9 and [lib #5](https://forge/other/lib/pulls/5); app #1",
                   merged_days=4),
          pull_hit(22, "closed unmerged", "Closes #5")]
OPEN = [pull_hit(n, t, b) for n, t, b in [
    (30, "held by a thread", "Refs #3"), (31, "reviewed earlier", ""), (32, "conflicting", ""),
    (33, "chore(deps): bump", "Release notes: other/tool#3 and https://github.com/up/stream/issues/4"), (34, "ready one", ""), (35, "draft, reported unmergeable", ""),
    (36, "reviewed for another branch", "Follows other/lib#2"), (37, "changes requested", "")]]
PULLS = {
    30: dict(user="me", mergeable=True), 31: dict(user="me", mergeable=True), 32: dict(user="me", mergeable=False),
    33: dict(user="renovate", mergeable=True), 34: dict(user="me", mergeable=True),
    35: dict(user="me", mergeable=False, draft=True), 36: dict(user="me", mergeable=True, base="main"),
    37: dict(user="me", mergeable=True),
}
COMMENTS = {30: [], 31: [{"body": "Automated read-only review (1234567 on dev): full: clean"}], 32: [],
            34: [{"body": f"Automated read-only review ({HEAD[:12]} on dev): full: clean"}], 35: [],
            36: [{"body": f"Automated read-only review ({HEAD[:12]} on dev): full: clean"}],
            37: [{"body": f"Automated read-only review ({HEAD[:12]} on dev): full: clean"}]}


def review(review_id, user, state, dismissed=False):
    return {"id": review_id, "user": {"login": user}, "state": state, "dismissed": dismissed}


# Each reviewer's latest verdict counts and comments do not change it; a dismissed latest verdict
# clears the reviewer's say without bringing back an older one.
REVIEWS = {34: [review(1, "ann", "REQUEST_CHANGES"), review(3, "ann", "APPROVED"), review(4, "bob", "COMMENT"),
                review(5, "cid", "REQUEST_CHANGES", dismissed=True), review(8, "dan", "REQUEST_CHANGES"),
                review(9, "dan", "REQUEST_CHANGES", dismissed=True)],
           37: [review(2, "bob", "APPROVED"), review(6, "ann", "REQUEST_CHANGES"), review(7, "ann", "COMMENT")]}


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
                 "updated_at": ago(0), "original_url": "", "default_branch": "main"},
                {"full_name": "me/old", "html_url": "https://forge/me/old", "archived": True, "mirror": False,
                 "updated_at": ago(0), "original_url": ""},
                {"full_name": "other/lib", "html_url": "https://forge/other/lib", "archived": True, "mirror": False,
                 "updated_at": ago(0), "original_url": ""},
                {"full_name": "other/tool", "html_url": "https://forge/other/tool", "archived": True, "mirror": False,
                 "updated_at": ago(0), "original_url": ""},
                {"full_name": "me/ghrepo", "html_url": "https://forge/me/ghrepo", "archived": False, "mirror": True,
                 "updated_at": ago(0), "original_url": "https://github.com/me/ghrepo.git"},
                # No issues or PRs: in thorough mode only its leftover branch gives it a row.
                {"full_name": "me/quiet", "html_url": "https://forge/me/quiet", "archived": False, "mirror": False,
                 "updated_at": ago(0), "original_url": "", "default_branch": "main"},
            ])
        if path == "/repos/issues/search":
            if query["type"] == "issues":
                return self.reply(ISSUES)
            return self.reply(MERGED if query["state"] == "closed" else OPEN)
        parts = path.strip("/").split("/")
        # Item mode reads me/notes: an issue with seven comments and a PR; anything else there is missing.
        if parts == ["repos", "me", "notes", "issues", "1"]:
            return self.reply({"number": 1, "title": "Notes issue", "body": "Line one\n\nLine two " + "x" * 100,
                               "updated_at": ago(1)})
        if parts == ["repos", "me", "notes", "issues", "1", "comments"]:
            return self.reply([{"user": {"login": f"user{n}"}, "created_at": ago(10 - n), "body": f"comment {n}"}
                               for n in range(1, 8)])
        if parts == ["repos", "me", "notes", "pulls", "2"]:
            return self.reply({"number": 2, "title": "Notes PR", "body": "Closes #1\nsecond line"})
        if parts[:3] == ["repos", "me", "notes"]:
            return self.reply({"message": SECRET}, 404)
        if parts == ["repos", "other", "lib", "issues", "2"]:
            return self.reply({"number": 2, "title": "Library fix", "state": "closed", "body": SECRET,
                               "html_url": "https://forge/other/lib/issues/2", "updated_at": ago(4), "closed_at": ago(4)})
        if parts == ["repos", "other", "tool", "issues", "3"]:
            return self.reply({"number": 3, "title": "Tool work", "state": "open", "body": SECRET,
                               "html_url": "https://forge/other/tool/issues/3", "updated_at": ago(4), "closed_at": None})
        if parts == ["repos", "me", "quiet", "branches"]:
            return self.reply([{"name": "main", "protected": False, "commit": {"id": "e" * 40, "timestamp": ago(1)}},
                               {"name": "stale-work", "protected": False, "commit": {"id": "f" * 40, "timestamp": ago(60)}}])
        if parts == ["repos", "me", "quiet", "pulls"]:
            return self.reply([])
        if parts[:4] == ["repos", "me", "app", "compare"]:
            base, _, branch = urllib.parse.unquote(parts[4]).partition("...")
            ahead = {"feat/done": 0, "feat/dropped": 2, "old-spike": 5}
            if base == "main" and branch in ahead:
                return self.reply({"total_commits": ahead[branch], "commits": [], "files": []})
        if parts == ["repos", "me", "app", "branches"]:
            return self.reply([
                {"name": name, "protected": name == "protected-one", "commit": {"id": "c" * 40, "timestamp": ago(days)}}
                for name, days in [("main", 1), ("dev", 1), ("feat/done", 40), ("feat/dropped", 5), ("feat/open", 2),
                                   ("old-spike", 90), ("new-spike", 3), ("renovate/x", 90), ("dev-next", 90),
                                   ("protected-one", 90), ("fork-named", 2), ("feat/reopened", 60)]])
        if parts == ["repos", "me", "app", "pulls"]:
            def pr(number, ref, state, merged=False, repo="me/app", updated=5, sha="c" * 40):
                return {"number": number, "state": state, "merged": merged, "merged_at": ago(30) if merged else None,
                        "closed_at": ago(5) if state == "closed" else None, "updated_at": ago(updated), "body": SECRET,
                        "head": {"ref": ref, "sha": sha, "repo": {"full_name": repo}}}
            return self.reply([pr(40, "feat/done", "closed", merged=True), pr(41, "feat/done", "closed", updated=50),
                               pr(42, "feat/dropped", "closed", sha="d" * 40), pr(43, "feat/open", "open"),
                               pr(44, "fork-named", "closed", merged=True, repo="someone/app"),
                               # A closed PR updated after the branch's open one must not hide the open one.
                               pr(45, "feat/reopened", "open", updated=20), pr(46, "feat/reopened", "closed", updated=1)])
        if parts[:3] == ["repos", "me", "app"] and parts[3] == "pulls" and parts[5:] == ["reviews"]:
            return self.reply(REVIEWS.get(int(parts[4]), []))
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
if os.environ.get("FAKE_GH_LOG"):
    with open(os.environ["FAKE_GH_LOG"], "a") as log:
        log.write(joined.split(chr(10))[0][:80] + chr(10))
if os.environ.get("FAKE_GH_RATE_LIMIT") and args[:2] == ["api", "repos/example-org/service"]:
    print("gh: API rate limit exceeded (HTTP 403)", file=sys.stderr)
    sys.exit(1)
if args[:2] == ["api", "user"]:
    out({"login": "me"})
if args[:2] == ["api", "repos/me/ghrepo"]:
    out({"html_url": "https://github.com/me/ghrepo", "pushed_at": now, "archived": False, "fork": False,
         "default_branch": "trunk"})
if args[:2] == ["api", "repos/example-org/service"]:
    out({"full_name": "example-org/service", "html_url": "https://github.com/example-org/service", "pushed_at": now,
         "archived": False, "fork": True})
if args[:2] in (["api", "repos/example-org/missing"], ["api", "repos/gone/repo/issues/1"]):
    print("gh: Not Found (HTTP 404)", file=sys.stderr)
    sys.exit(1)
if "repos/example-org/service/issues?state=open" in joined:
    out([[{"number": 11, "title": "Org issue", "body": "Needs me/ghrepo#1 BODY-TEXT-MUST-NOT-LEAK",
           "html_url": "https://github.com/example-org/service/issues/11", "user": {"login": "someone"},
           "created_at": now, "updated_at": now, "comments": 0, "labels": [], "milestone": None, "assignees": []}]])
if "repos/example-org/service/pulls?state=closed" in joined:
    out([])
if args[:2] == ["api", "repos/me/ghrepo/issues/1"]:
    out({"number": 1, "title": "GitHub issue", "state": "open", "html_url": "https://github.com/me/ghrepo/issues/1",
         "updated_at": now, "closed_at": None})
if args[:2] == ["api", "repos/up/stream/issues/4"]:
    out({"number": 4, "title": "Upstream PR", "state": "closed", "pull_request": {"merged_at": now},
         "html_url": "https://github.com/up/stream/pull/4", "updated_at": now, "closed_at": now})
if args[:2] == ["api", "graphql"] and os.environ.get("FAKE_GH_COMPARE_FAIL") and "compare(" in joined:
    print("gh: GraphQL: query too complex", file=sys.stderr)
    sys.exit(1)
if args[:2] == ["api", "graphql"]:
    if "name=service" in args:
        print("gh: GraphQL: Resource not accessible by integration", file=sys.stderr)
        sys.exit(1)
    if "base=trunk" not in args and "compare(" in joined:
        print("gh: the default branch was not passed", file=sys.stderr)
        sys.exit(1)
    def ref(name, days, pr=None, open_prs=0, ahead=0):
        node = {"name": name, "target": {"oid": name[0] * 40, "committedDate": days},
                "associatedPullRequests": {"nodes": [pr] if pr else []}, "open": {"totalCount": open_prs}}
        return {**node, "compare": {"behindBy": ahead}} if "compare(" in joined else node
    out({"data": {"repository": {"defaultBranchRef": {"name": "trunk"}, "refs": {"totalCount": 4, "nodes": [
        ref("trunk", now), ref("main", "2020-01-01T00:00:00Z"),
        ref("fix/thing", now, {"number": 7, "state": "MERGED", "mergedAt": now, "closedAt": now, "headRefOid": "f" * 40}),
        ref("wip", "2020-01-01T00:00:00Z", ahead=3), ref("release/1", "2020-01-01T00:00:00Z"),
        ref("shared", "2020-01-01T00:00:00Z", {"number": 8, "state": "CLOSED", "mergedAt": None, "closedAt": now}, 1)]}}}})
if "repos/me/ghrepo/branches?protected=true" in joined:
    out([{"name": "release/1", "protected": True}])
if "repos/me/ghrepo/issues?state=open" in joined:
    # With FAKE_GH_APP, an App's issue links an upstream item.
    app_issue = [{"number": 3, "title": "Filed by the App", "body": "See https://github.com/up/stream/issues/4",
                  "html_url": "https://github.com/me/ghrepo/issues/3", "user": {"login": "hugin[bot]"},
                  "created_at": now, "updated_at": now, "comments": 0, "labels": [], "milestone": None,
                  "assignees": []}] if os.environ.get("FAKE_GH_APP") else []
    out([[{"number": 1, "title": "GitHub issue", "body": "- [x] done BODY-TEXT-MUST-NOT-LEAK",
           "html_url": "https://github.com/me/ghrepo/issues/1", "user": {"login": "me"},
           "created_at": now, "updated_at": now, "comments": 0, "labels": [], "milestone": None, "assignees": []},
          {"number": 2, "title": "a PR", "pull_request": {}}, *app_issue]])
# Item mode: an upstream issue with two comments and its PR; issue 6 fails.
if args[:2] == ["api", "repos/up/stream/issues/5"]:
    out({"number": 5, "title": "Upstream issue", "body": "Upstream body\nwith lines", "updated_at": now})
if args[:4] == ["api", "--paginate", "--slurp", "repos/up/stream/issues/5/comments?per_page=100"]:
    out([[{"user": {"login": "ann"}, "created_at": "2026-01-01T00:00:00Z", "body": "first"}],
         [{"user": {"login": "bob"}, "created_at": "2026-01-02T00:00:00Z", "body": "second"}]])
if args[:2] == ["api", "repos/up/stream/pulls/9"]:
    out({"number": 9, "title": "Upstream PR", "body": "Fixes #5"})
if args[:2] == ["api", "repos/up/stream/issues/6"]:
    print("gh: Not Found (HTTP 404)", file=sys.stderr)
    sys.exit(1)
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
         "url": f"https://github.com/{args[4]}/pull/{number}",
         "author": {"login": "app/hugin" if number == 2 and os.environ.get("FAKE_GH_APP") else "me"}, "isDraft": False,
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
            {"threadId": "t-old", "title": "Settled thread (app #6)", "bucket": "recently-settled", "status": "idle",
             "prs": [{"url": "https://forge/me/app/pulls/32", "state": "open"}]},
            # A live thread names an issue by repository name, or by number in its project's repository.
            {"threadId": "t-named", "title": "Finish the status work (app #5)", "bucket": "unsettled",
             "status": "idle", "project": "elsewhere", "prs": []},
            {"threadId": "t-project", "title": "Fix the status date (#9)", "bucket": "unsettled", "status": "idle",
             "project": "app", "prs": []},
            {"threadId": "t-unknown", "title": "Look at #6", "bucket": "unsettled", "status": "idle",
             "project": "src", "prs": []},
            # An issue URL names its forge: a Forgejo URL is not the GitHub issue of the same name.
            {"threadId": "t-forgejo-url", "title": f"See {base}/me/ghrepo/issues/1", "bucket": "unsettled",
             "status": "idle", "project": "src", "prs": []},
            {"threadId": "t-github-url", "title": "Fix https://github.com/me/ghrepo/issues/1", "bucket": "unsettled",
             "status": "idle", "project": "src", "prs": []}]}))
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
        check(report["sources"] == {"forgejo": base, "github": "ok", "threads": "ok", "related": "ok", "branches": "skipped"},
              f"sources: {report['sources']}")
        check(report["scope"] == {"kind": "all", "groups": [], "repos": [], "missing": []}, f"scope: {report['scope']}")
        check(report["branches"] == [], "branches listed without --branches")

        issues = {i["ref"]: i for i in report["issues"]}
        lanes = {ref: i["lane"] for ref, i in issues.items()}
        check(lanes == {"me/app#1": "close", "me/app#2": "close", "me/app#3": "inflight", "me/app#4": "stale",
                        "me/app#5": "inflight", "me/app#6": "active", "me/app#7": "dashboard", "me/app#8": "active",
                        "me/app#9": "inflight", "gh:me/ghrepo#1": "close"},
              f"issue lanes: {lanes}")
        check(issues["me/app#5"]["thread"]["threadId"] == "t-named" and issues["me/app#9"]["thread"]["threadId"] == "t-project"
              and issues["me/app#6"]["thread"] is None and issues["me/app#3"]["thread"] is None
              and issues["gh:me/ghrepo#1"]["thread"]["threadId"] == "t-github-url",
              f"threads naming issues: {[(r, i['thread']) for r, i in issues.items()]}")
        # Mentions of other repositories' items in a merged PR are not this repository's.
        check(issues["me/app#9"]["mergedPrs"] == [] and issues["me/app#5"]["mergedPrs"] == []
              and [p["ref"] for p in issues["me/app#1"]["mergedPrs"]] == ["me/app#24"],
              f"mentions by name: {issues['me/app#9']['mergedPrs']} {issues['me/app#1']['mergedPrs']}")
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
                           "me/app#34": "ready", "me/app#35": "open", "me/app#36": "open", "me/app#37": "blocked",
                           "gh:me/ghrepo#2": "open", "gh:up/stream#9": "ready"},
              f"PR lanes: {pr_lanes}")
        check(prs["me/app#30"]["thread"]["threadId"] == "t-live", "thread not joined")
        check("conflict" not in prs["me/app#35"]["flags"], "a draft was called conflicting")
        check(prs["me/app#36"]["review"] == "outdated", "a review for another target branch counted")
        # ADR-0093: a PR with changes requested is blocked, even when it is green and reviewed at its head.
        check(prs["me/app#37"]["reviewDecision"] == "changes-requested" and "changes-requested" in prs["me/app#37"]["flags"],
              f"Forgejo changes requested: {prs['me/app#37']}")
        check(prs["me/app#34"]["reviewDecision"] == "approved" and prs["me/app#30"]["reviewDecision"] is None,
              f"Forgejo review decisions: {prs['me/app#34']['reviewDecision']} {prs['me/app#30']['reviewDecision']}")
        check({"review-outdated", "orphan"} <= set(prs["me/app#31"]["flags"]), f"flags: {prs['me/app#31']['flags']}")
        check({"conflict", "thread-settled", "orphan"} <= set(prs["me/app#32"]["flags"]), f"flags: {prs['me/app#32']['flags']}")
        check(prs["gh:me/ghrepo#2"]["issues"] == ["gh:me/ghrepo#1"] and prs["gh:me/ghrepo#2"]["review"] == "none",
              f"GitHub PR: {prs['gh:me/ghrepo#2']}")
        check(prs["gh:up/stream#9"]["kind"] == "upstream" and prs["gh:up/stream#9"]["reviewDecision"] == "approved",
              f"upstream PR: {prs['gh:up/stream#9']}")
        repos = [(r["forge"], r["repo"]) for r in report["repos"]]
        check(repos[0] == ("forgejo", "me/app") and ("github", "up/stream") in repos, f"repos: {repos}")
        check(report["totals"]["issues"] == 10 and report["totals"]["prs"] == 10 and report["totals"]["repos"] == len(repos),
              f"totals: {report['totals']}")

        # Items in repositories outside the scope are pulled in once, with their state and sources.
        related = {r["ref"]: r for r in report["related"]}
        # gone/repo is not a repository the token can list, so its short ref is not looked up on Forgejo;
        # gh:me/old is the push mirror of a Forgejo-first repository, whose issues live on Forgejo.
        check(set(related) == {"other/lib#2", "other/tool#3", "me/old#99", "gh:up/stream#4"}, f"related: {sorted(related)}")
        check(related["other/lib#2"]["state"] == "closed" and related["other/lib#2"]["kind"] == "issue"
              and related["other/lib#2"]["pulledBy"] == ["me/app#4", "me/app#9", "me/app#36"], f"related: {related['other/lib#2']}")
        # Renovate's release notes pull nothing in; one related item still open means no related-closed.
        check(prs["me/app#33"]["related"] == [] and related["other/tool#3"]["pulledBy"] == ["me/app#9"]
              and "me/app#33" not in related["gh:up/stream#4"]["pulledBy"], f"a Renovate row pulled items in: {related}")
        check(issues["me/app#9"]["related"] == ["other/lib#2", "other/tool#3"] and "related-closed" not in issues["me/app#9"]["flags"],
              f"related-closed with an open related item: {issues['me/app#9']}")
        check(related["gh:up/stream#4"]["state"] == "merged" and related["gh:up/stream#4"]["kind"] == "pr",
              f"related: {related['gh:up/stream#4']}")
        check(related["me/old#99"]["state"] == "unavailable", "a failed lookup was not marked unavailable")
        check(issues["me/app#4"]["related"] == ["me/old#99", "other/lib#2", "gh:up/stream#4"]
              and "related-closed" in issues["me/app#4"]["flags"], f"source of related items: {issues['me/app#4']}")
        check(prs["me/app#36"]["related"] == ["other/lib#2"] and "related-closed" in prs["me/app#36"]["flags"],
              f"PR source of a related item: {prs['me/app#36']}")
        check(report["totals"]["related"] == 4 and all("links" not in row for row in report["issues"] + report["prs"]),
              "related totals or internal fields")

        result = run("--threads", str(threads), "--related", "0")
        report = json.loads(result.stdout)
        check(report["related"] == [] and report["sources"]["related"] == "off", "--related 0 still pulled items in")

        # Thorough mode: leftover branches whose PR merged or closed, or that never had one.
        result = run("--branches", "--related", "0")
        check(result.returncode == 0, f"--branches failed: {result.stderr}")
        report = json.loads(result.stdout)
        branches = {b["ref"]: (b["lane"], (b["pr"] or {}).get("ref")) for b in report["branches"]}
        check(branches == {"me/app@feat/done": ("merged", "me/app#40"), "me/app@feat/dropped": ("closed", "me/app#42"),
                           "me/app@old-spike": ("no-pr", None), "gh:me/ghrepo@fix/thing": ("merged", "gh:me/ghrepo#7"),
                           "gh:me/ghrepo@wip": ("no-pr", None), "me/quiet@stale-work": ("no-pr", None)},
              f"branches: {branches}")
        check(report["sources"]["branches"] == "ok" and report["totals"]["branchLanes"] == {"closed": 1, "merged": 2, "no-pr": 3},
              f"branch sources or totals: {report['sources']} {report['totals']}")
        check(next(r for r in report["repos"] if r["repo"] == "me/ghrepo")["branches"] == 2, "repository branch count")
        # The branch head, its last PR's head and the commits not in the default branch (null when unknown).
        heads = {b["ref"]: (b["head"], (b["pr"] or {}).get("head"), b["ahead"], b["aheadOf"]) for b in report["branches"]}
        check(heads == {"me/app@feat/done": ("c" * 40, "c" * 40, 0, "main"), "me/app@feat/dropped": ("c" * 40, "d" * 40, 2, "main"),
                        "me/app@old-spike": ("c" * 40, None, 5, "main"), "gh:me/ghrepo@fix/thing": ("f" * 40, "f" * 40, 0, "trunk"),
                        "gh:me/ghrepo@wip": ("w" * 40, None, 3, "trunk"), "me/quiet@stale-work": ("f" * 40, None, None, "main")},
              f"branch heads: {heads}")
        # Every branch read is either listed or counted as skipped, with the reason.
        scan = {s["repo"]: s for s in report["branchScan"]}
        check(scan == {"me/app": {"repo": "me/app", "read": 12, "listed": 3, "truncated": False,
                                  "skipped": {"kept": 4, "open-pr": 2, "recent": 2, "protected": 1}},
                       "me/quiet": {"repo": "me/quiet", "read": 2, "listed": 1, "truncated": False, "skipped": {"kept": 1}},
                       "gh:me/ghrepo": {"repo": "gh:me/ghrepo", "read": 6, "listed": 2, "truncated": False,
                                        "skipped": {"kept": 2, "protected": 1, "open-pr": 1}}}, f"branch scan: {scan}")
        check(report["totals"]["branchesRead"] == 20 and report["totals"]["branchesSkipped"] == 14, f"totals: {report['totals']}")
        # A repository with only a leftover branch has a row, and the totals count it.
        check(any(r["repo"] == "me/quiet" for r in report["repos"]) and report["totals"]["repos"] == len(report["repos"]),
              f"repository totals: {report['totals']['repos']} {[r['repo'] for r in report['repos']]}")

        # A GitHub query too costly with the comparisons still gives the branch rows, without `ahead`.
        result = run("--branches", "--related", "0", extra={"FAKE_GH_COMPARE_FAIL": "1"})
        report = json.loads(result.stdout)
        gh_rows = {b["ref"]: b["ahead"] for b in report["branches"] if b["forge"] == "github"}
        check(report["sources"]["branches"] == "ok" and gh_rows == {"gh:me/ghrepo@fix/thing": None, "gh:me/ghrepo@wip": None},
              f"a failed comparison lost GitHub branch rows: {report['sources']} {gh_rows}")

        # A narrower scope reads only its repositories: no GitHub for a Forgejo repository.
        log = tmp / "gh.log"
        result = run("--scope", "me/app", extra={"FAKE_GH_LOG": str(log)})
        report = json.loads(result.stdout)
        check(result.returncode == 0 and report["sources"]["github"] == "skipped"
              and sorted(log.read_text().splitlines()) == ["api repos/up/stream/issues/4", "api repos/up/stream/issues/9"],
              f"a Forgejo scope read GitHub beyond pulled-in items: {report['sources']}")
        check(report["scope"] == {"kind": "selected", "groups": [], "repos": ["me/app"], "missing": []},
              f"scope: {report['scope']}")
        check({i["repo"] for i in report["issues"]} == {"me/app"}, "another repository's issue in a narrow scope")
        # GitHub is skipped for the rows, but pulled-in GitHub items are still looked up.
        check(next(r for r in report["related"] if r["ref"] == "gh:up/stream#4")["state"] == "merged",
              f"a GitHub item was not looked up in a Forgejo scope: {report['related']}")
        log.unlink()

        # A group from the scope file: its GitHub repositories, named forks included, no upstream PR search.
        scopes = tmp / "scopes.json"
        scopes.write_text(json.dumps({"groups": {"work": {"description": "made-up",
                                                          "repos": ["gh:example-org/service", "gh:example-org/missing"]}}}))
        result = run("--scope", "work", "--scope", "me/nothere", "--branches",
                     extra={"FAKE_GH_LOG": str(log), "BACKLOG_SCOPE_FILE": str(scopes)})
        check(result.returncode == 0, f"group scope failed: {result.stderr}")
        report = json.loads(result.stdout)
        check(report["scope"] == {"kind": "selected", "groups": ["work"], "repos": ["me/nothere"],
                                  "missing": ["gh:example-org/missing", "me/nothere"]}, f"scope: {report['scope']}")
        check([i["ref"] for i in report["issues"]] == ["gh:example-org/service#11"] and report["prs"] == [],
              f"group rows: {[i['ref'] for i in report['issues']]}")
        check(not any(line.startswith("search prs") for line in log.read_text().splitlines()),
              "a group scope searched the user's upstream PRs")
        check([(r["ref"], r["state"]) for r in report["related"]] == [("gh:me/ghrepo#1", "open")],
              f"related outside the group: {report['related']}")
        check(report["sources"]["branches"].startswith("partial: 1 of 1 repositories failed (gh:example-org/service)"),
              f"branch failure: {report['sources']['branches']}")
        # A rate limit is no missing repository: GitHub fails as a whole, and no GitHub item is pulled in.
        result = run("--scope", "work", "--scope", "me/app", extra={"BACKLOG_SCOPE_FILE": str(scopes), "FAKE_GH_RATE_LIMIT": "1"})
        report = json.loads(result.stdout)
        check(report["sources"]["github"].startswith("error:") and "gh:example-org/service" not in report["scope"]["missing"]
              and not any(r["forge"] == "github" for r in report["related"]),
              f"a rate limit was reported as a missing repository: {report['sources']} {report['scope']} {report['related']}")
        check(run("--scope-file", str(scopes), "--scope", "nosuch").returncode == 64, "an unknown group was accepted")
        for bad in ('{"groups": {"work": {"repos": []}}}', '{"groups": {"all": {"repos": ["a/b"]}}}', "[1]", "{"):
            scopes.write_text(bad)
            check(run("--scope-file", str(scopes)).returncode == 64, f"a malformed scope file was accepted: {bad}")
        check(run("--scope-file", str(tmp / "absent.json")).returncode == 64, "a missing scope file was accepted")

        # An installation token cannot say who it is: --github-user stands in, and the upstream search is skipped.
        log.unlink(missing_ok=True)
        result = run("--github-user", "me", "--related", "0", extra={"FAKE_GH_LOG": str(log)})
        check(result.returncode == 0, f"--github-user failed: {result.stderr}")
        report = json.loads(result.stdout)
        calls = log.read_text().splitlines()
        check("api user" not in calls and not any(c.startswith("search prs") for c in calls)
              and "gh:up/stream#9" not in {p["ref"] for p in report["prs"]}
              and next(p for p in report["prs"] if p["ref"] == "gh:me/ghrepo#2")["kind"] == "own",
              f"--github-user still asked gh: {calls}")
        for bad in ("bad_name", "a" * 40, "-me", ""):
            check(run("--github-user", bad).returncode == 64, f"--github-user {bad!r} was accepted")

        # An App acting for the user: its PRs are own with a real lane, and its issues' links pull items in.
        result = run("--threads", str(threads), extra={"FAKE_GH_APP": "1"})
        report = json.loads(result.stdout)
        app_pr = next(p for p in report["prs"] if p["ref"] == "gh:me/ghrepo#2")
        check(app_pr["kind"] == "bot" and app_pr["lane"] == "renovate"
              and "gh:me/ghrepo#3" not in next(r for r in report["related"] if r["ref"] == "gh:up/stream#4")["pulledBy"],
              f"an App author counted without --own: {app_pr}")
        result = run("--threads", str(threads), "--own", "app/hugin", "--own", "hugin[bot]", extra={"FAKE_GH_APP": "1"})
        check(result.returncode == 0, f"--own failed: {result.stderr}")
        report = json.loads(result.stdout)
        app_pr = next(p for p in report["prs"] if p["ref"] == "gh:me/ghrepo#2")
        app_issue = next(i for i in report["issues"] if i["ref"] == "gh:me/ghrepo#3")
        check(app_pr["kind"] == "own" and app_pr["lane"] == "open" and app_pr["review"] == "none"
              and "review-missing" in app_pr["flags"], f"an --own PR: {app_pr}")
        check(app_issue["lane"] == "active" and app_issue["related"] == ["gh:up/stream#4"]
              and "gh:me/ghrepo#3" in next(r for r in report["related"] if r["ref"] == "gh:up/stream#4")["pulledBy"],
              f"an --own issue author's links did not feed related: {app_issue}")
        for bad in ("app/", "x[bot]y", "a b", "app/x[bot]", "-x"):
            check(run("--own", bad).returncode == 64, f"--own {bad!r} was accepted")

        # Item mode prints the text the inventory never does: cut to --max-chars, newlines kept, last five comments.
        result = run("item", "--max-chars", "50", "me/notes#1", "me/notes#2")
        check(result.returncode == 0, f"item mode failed: {result.stderr}")
        item = json.loads(result.stdout)
        check(set(item) == {"ref", "title", "body", "updatedAt", "comments", "prs"} and item["ref"] == "me/notes#1"
              and item["title"] == "Notes issue" and item["updatedAt"] == ago(1), f"item: {item}")
        check(len(item["body"]) == 50 and item["body"].startswith("Line one\n\nLine two x") and item["body"].endswith("x…"),
              f"item body not cut at 50 with newlines kept: {item['body']!r}")
        check([c["author"] for c in item["comments"]] == [f"user{n}" for n in range(3, 8)]
              and item["comments"][0] == {"author": "user3", "createdAt": ago(7), "body": "comment 3"},
              f"item comments are not the last five, oldest first: {item['comments']}")
        check(item["prs"] == [{"ref": "me/notes#2", "title": "Notes PR", "body": "Closes #1\nsecond line"}],
              f"item PRs: {item['prs']}")
        # A GitHub-only item needs no Forgejo token; PRs follow the given order.
        result = run("item", "--max-chars", "20000", "gh:up/stream#5", "gh:up/stream#9", "me/notes#2",
                     extra={"FORGEJO_API_TOKEN_FILE": str(tmp / "missing")})
        check(result.returncode == 2, f"a Forgejo PR ref without a token did not exit 2: {result.returncode}")
        result = run("item", "--max-chars", "20000", "gh:up/stream#5", "gh:up/stream#9",
                     extra={"FORGEJO_API_TOKEN_FILE": str(tmp / "missing")})
        check(result.returncode == 0, f"GitHub item mode failed: {result.stderr}")
        item = json.loads(result.stdout)
        check(item["body"] == "Upstream body\nwith lines" and [c["author"] for c in item["comments"]] == ["ann", "bob"]
              and item["prs"] == [{"ref": "gh:up/stream#9", "title": "Upstream PR", "body": "Fixes #5"}],
              f"GitHub item: {item}")
        # A failed request names the ref and status, prints nothing else and leaks no text from the response.
        for refs, named, status in ((["me/notes#3"], "me/notes#3", "404"), (["me/notes#1", "me/notes#99"], "me/notes#99", "404"),
                                    (["gh:up/stream#6"], "gh:up/stream#6", "HTTP 404")):
            result = run("item", "--max-chars", "100", *refs)
            check(result.returncode == 3 and result.stdout == "" and named in result.stderr and status in result.stderr
                  and SECRET not in result.stderr and "Notes issue" not in result.stderr
                  and len(result.stderr.strip().splitlines()) == 1, f"failed item {refs}: {result.returncode} {result.stderr}")
        for bad in (["--max-chars", "50", "me/notes"], ["--max-chars", "50", "me/notes#0"], ["--max-chars", "50", "me/notes#1x"],
                    ["--max-chars", "50", "-me/notes#1"], ["--max-chars", "50", "--", "-me/notes#1"],
                    ["--max-chars", "50", "../..#1"], ["--max-chars", "50", "gh:me/a/b#1"], ["--max-chars", "50", "me/notes#1", "x"],
                    ["--max-chars", "50", "me/notes#1", "me/notes#2", "me/notes#2", "me/notes#2", "me/notes#2"],
                    ["--max-chars", "0", "me/notes#1"], ["--max-chars", "20001", "me/notes#1"], ["--max-chars", "x", "me/notes#1"],
                    ["me/notes#1"], ["--max", "50", "me/notes#1"]):
            check(run("item", *bad).returncode == 64, f"item usage {bad} did not exit 64")
        check(run("item", "--max-chars", "50", "me/notes#1", extra={"FORGEJO_API_TOKEN_FILE": str(tmp / "missing")}).returncode
              == 2, "a Forgejo item without a token did not exit 2")

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
        check(run("--related", "-1").returncode == 64, "a bad --related did not exit 64")
        Forge.redirect = True
        result = run("--no-github")
        check(result.returncode == 3 and "302" in result.stderr, f"a redirect was followed: {result.returncode} {result.stderr}")
    server.shutdown()
    print("backlog-inventory contract tests passed")


if __name__ == "__main__":
    main()
