"""Contract tests for pr-review and the agent PR review guard hook."""

import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "pr_review", ROOT / "modules/home-manager/programs/ai/pr-review.py"
)
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)
real_run = review.run
real_forgejo = review.forgejo_request

HEAD = "0123456789abcdef0123456789abcdef01234567"
PINNED = f"Automated read-only review ({HEAD[:12]} on dev): no blocking findings."
STALE = "Automated read-only review (fedcba987654 on dev): no blocking findings."
calls = []


def bodies_for(number):
    return {"7": ["LGTM", PINNED], "9": [STALE]}.get(number, ["LGTM"])


def fake_run(argv, cwd=None, stdin=None, timeout=None):
    calls.append((argv, cwd))
    joined = " ".join(argv)
    if argv[:3] == ["gh", "pr", "view"]:
        number = "7" if "reviewed" in joined or "7" in argv else "9" if "9" in argv else "5"
        host = "ghe.example" if "ghe" in joined else "github.com"
        return json.dumps({"bodies": bodies_for(number), "head": HEAD, "base": "dev",
                           "url": f"https://{host}/o/r/pull/{number}"})
    number = joined.split("/")[4].split()[0] if "/pulls/" in joined or "/issues/" in joined else "5"
    if "/comments" in joined:
        return "\n".join(json.dumps(body) for body in bodies_for(number))
    return json.dumps({"head": {"sha": HEAD}, "base": {"ref": "dev"}, "title": "t"})


def fake_forgejo(pr, path, data=None, accept="application/json"):
    calls.append((pr, path))
    if path.startswith("issues/"):
        return [{"body": body} for body in bodies_for(pr.number)]
    return {"head": {"sha": HEAD}, "base": {"ref": "dev"}, "title": "t"}


review.run = fake_run
review.forgejo_request = fake_forgejo


def hook(command, cwd="/work"):
    sys.stdin = io.StringIO(json.dumps({"tool_input": {"command": command}, "cwd": cwd}))
    sys.stderr = io.StringIO()
    try:
        return review.main(["guard"]), sys.stderr.getvalue()
    finally:
        sys.stdin, sys.stderr = sys.__stdin__, sys.__stderr__


def expect(command, status, cwd="/work"):
    calls.clear()
    code, message = hook(command, cwd)
    assert code == status, f"{command!r}: expected {status}, got {code}: {message}"
    if status == 2:
        assert "pr-review run <pr>" in message, message
    return list(calls), message


# Unrelated commands and non-merge calls pass without lookups.
assert not expect("git merge origin/main", 0)[0]
assert not expect("gh pr view 5", 0)[0]
assert not expect("echo hello", 0)[0]

# gh pr merge resolves selector, repository and cwd for gh pr view.
seen, _ = expect("gh pr merge 5 --squash --body 'x y' -R owner/repo", 2)
assert seen[0][0][:6] == ["gh", "pr", "view", "5", "--repo", "owner/repo"], seen
seen, _ = expect("cd sub && gh pr merge 7 --squash", 0)
assert seen[0][1] == "/work/sub", seen
expect("gh pr merge --repo=owner/reviewed --squash", 0)

# A review of an earlier head does not count.
_, message = expect("gh pr merge 9 --squash", 2)
assert f"current head {HEAD[:12]}" in message, message

# GitHub API and Forgejo REST merges.
expect("gh api -X PUT repos/o/r/pulls/7/merge -f merge_method=squash", 0)
expect("gh api -X PUT repos/o/r/pulls/8/merge", 2)
seen, _ = expect("curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge -d '{}'", 0)
assert seen[0][0].host == "https://git.example", seen
expect("curl -X POST https://git.example/api/v1/repos/o/r/pulls/9/merge", 2)
expect('curl -X POST "$FORGEJO/api/v1/repos/o/r/pulls/8/merge"', 2)
expect("curl --request GET https://git.example/api/v1/repos/o/r/pulls/8/merge", 0)

# fj merges are verified like REST merges and need literal targets; tea merges are refused.
seen, _ = expect("fj pr merge o/r#7 -M squash -d", 0)
assert (seen[0][0].host, seen[0][0].owner, seen[0][0].repo, seen[0][0].number) == (review.FORGEJO_URL, "o", "r", "7"), seen
expect("fj -H git.alc.xyz pr merge --method=squash o/r#9", 2)
expect("cd x && fj pr merge -m 'body' o/r#7", 0)
# Simple redirections at the end of a one-line merge are not arguments.
expect("fj pr merge o/r#7 --method squash -t 'x' -m 'y z' 2>&1 | tail -5", 0)
expect("fj pr merge o/r#7 >/dev/null 2>&1", 0)
expect("fj pr merge o/r#7 &>>log |& head -n 20\n", 0)
expect("fj pr merge o/r#7 -m 'a 2>&1'", 0)
expect("fj pr merge o/r#9 2>&1 | tail -5", 2)
seen, _ = expect("gh pr merge 9 --squash 2>&1 | tail -3", 2)
assert seen[0][0][3] == "9", seen
expect("gh pr merge 7 --squash >/dev/null", 0)
for command, hint in (
    ("fj pr merge 7", "owner/repo#N"),
    ("fj pr merge -R origin o/r#7", "owner/repo#N"),
    ("fj --host codeberg.org pr merge o/r#7", "only https://git.alc.xyz"),
    ("fj -Hcodeberg.org pr merge o/r#7", "only https://git.alc.xyz"),
    ("fj --ssh x pr merge o/r#7", "fj pr merge owner/repo#N"),
    ("fj pr merge o/r#7\necho --help", "fj pr merge owner/repo#N"),
    ("fj pr merge o/r#7 extra", "arguments as: o/r#7 extra"),
    # Other redirections are still read as arguments, so the merge is refused.
    ("fj pr merge 2>/dev/null o/r#7", "arguments as: 2>/dev/null o/r#7"),
    ("fj pr merge o/r#7 \\ >x", "fj pr merge owner/repo#N"),
    ("fj pr merge o/r#7 2>&1\necho", "fj pr merge owner/repo#N"),
    ("fj pr merge o/r#7 2>&1 | fj pr merge o/r#8", "fj pr merge owner/repo#N"),
    ("fj pr merge o/r#7\r2>&1", "fj pr merge owner/repo#N"),
    ("fj pr merge o/r#7 \u0663>x", "arguments as: o/r#7 \u0663>x"),
    ("fj pr merge o/r#7 '>' x", "arguments as: o/r#7 > x"),
    ("tea pulls merge --repo o/r 7", "use `fj pr merge"),
    ("tea pr m -r o/r 7", "use `fj pr merge"),
    ("tea pulls --fields index merge --repo o/r 7", "use `fj pr merge"),
):
    calls.clear()
    code, message = hook(command)
    assert code == 2 and hint in message and not calls, (command, message)
# A reviewed fj merge does not let another merge in the same command through.
expect("fj pr merge o/r#7 && gh pr merge 9", 2)
expect("fj pr merge o/r#7; curl -X POST https://git.example/api/v1/repos/o/r/pulls/8/merge", 2)
expect("fj pr merge o/r#7; fj pr merge o/r#8", 2)
expect("fj pr merge o/r#7 && tea pulls merge --repo o/r 7", 2)
assert not expect("fj pr view o/r#7", 0)[0]
assert not expect("tea pulls list --repo o/r", 0)[0]
assert not expect("echo fj; tea issues ls", 0)[0]


# Forgejo MCP tools other than merges pass without lookups (ADR-0081).
def mcp_hook(tool, tool_input=None):
    tool_input = {"owner": "o", "repo": "r", "index": 7} if tool_input is None else tool_input
    sys.stdin = io.StringIO(json.dumps({"tool_name": tool, "tool_input": tool_input}))
    sys.stderr = io.StringIO()
    try:
        return review.main(["guard"]), sys.stderr.getvalue()
    finally:
        sys.stdin, sys.stderr = sys.__stdin__, sys.__stderr__


calls.clear()
for tool in ("get_issue_by_index", "create_issue_comment", "dispatch_workflow", "delete_branch"):
    assert mcp_hook(f"mcp__forgejo__{tool}") == (0, ""), tool
assert mcp_hook("mcp__other__merge_pull_request")[0] == 0
assert not calls, calls

# An MCP merge is verified like other merges, on the MCP server's instance.
with tempfile.TemporaryDirectory() as state:
    os.environ["AGENT_MCP_STATE_DIR"] = state
    for client in ("codex", "claude"):
        pathlib.Path(state, f"{client}-managed.json").write_text(json.dumps({"managed": ["forgejo"]}))
    merge = "mcp__forgejo__merge_pull_request"
    calls.clear()
    code, message = mcp_hook(merge, {"owner": "o", "repo": "r", "index": 7, "style": "squash", "title": "t"})
    assert code == 0, message
    assert (calls[0][0].host, calls[0][0].owner, calls[0][0].repo, calls[0][0].number) == (
        review.FORGEJO_MCP_URL, "o", "r", "7"), calls
    assert mcp_hook(merge, {"owner": "o", "repo": "r", "index": 7.0, "style": "merge"})[0] == 0
    code, message = mcp_hook(merge, {"owner": "o", "repo": "r", "index": 9, "style": "squash"})
    assert code == 2 and f"current head {HEAD[:12]}" in message and "pr-review run <pr>" in message, message
    for arguments, hint in (
        ({"owner": "o", "repo": "r", "index": 7, "style": "squash", "force_merge": True}, "force_merge"),
        ({"owner": "o", "repo": "r", "index": 7, "style": "squash", "merge_when_checks_succeed": True},
         "merge_when_checks_succeed"),
        ({"owner": "..", "repo": "r", "index": 7, "style": "squash"}, "literal values"),
        ({"owner": "o", "repo": "r/x", "index": 7, "style": "squash"}, "literal values"),
        ({"owner": "o", "repo": "r", "index": "7", "style": "squash"}, "literal values"),
        ({"owner": "o", "repo": "r", "index": True, "style": "squash"}, "literal values"),
        ({"owner": "o", "repo": "r", "index": 7.5, "style": "squash"}, "literal values"),
        ({"owner": "o", "repo": "r", "style": "squash"}, "literal values"),
        ({"owner": "o", "repo": "r", "index": 7, "style": "squash", "auto_merge": True}, "unexpected arguments auto_merge"),
        ([], "no arguments"),
    ):
        calls.clear()
        code, message = mcp_hook(merge, arguments)
        assert code == 2 and hint in message and not calls, (arguments, message)
    assert mcp_hook(merge, {"owner": "o", "repo": "r", "index": 7, "style": "squash", "force_merge": False,
                            "merge_when_checks_succeed": False, "delete_branch_after_merge": True})[0] == 0
    # A `forgejo` server that programs.ai does not manage for either client may
    # point elsewhere: MCP merges are refused.
    reviewed = {"owner": "o", "repo": "r", "index": 7, "style": "squash"}
    claude_state = pathlib.Path(state, "claude-managed.json")
    for content in (json.dumps({"managed": []}), "{not json", json.dumps({"managed": "forgejo"}), None):
        if content is None:
            claude_state.unlink()
        else:
            claude_state.write_text(content)
        calls.clear()
        code, message = mcp_hook(merge, reviewed)
        assert code == 2 and "not the one programs.ai manages" in message and not calls, (content, message)
    claude_state.write_text(json.dumps({"managed": ["forgejo"]}))
    assert mcp_hook(merge, reviewed)[0] == 0
    # The lookup only covers the guard's own instance.
    review.FORGEJO_MCP_URL = "https://other.example"
    code, message = mcp_hook(merge, reviewed)
    assert code == 2 and "only when the server uses" in message, message
    review.FORGEJO_MCP_URL = review.FORGEJO_URL
    del os.environ["AGENT_MCP_STATE_DIR"]
# Without the registration state, MCP merges are refused.
code, message = mcp_hook("mcp__forgejo__merge_pull_request", {"owner": "o", "repo": "r", "index": 7})
assert code == 2 and "not the one programs.ai manages" in message, message

# Unresolvable merge targets block with guidance.
code, message = hook("curl -X POST https://git.example/api/v1/repos/o/r/pulls/$PR/merge")
assert code == 2 and "literal owner" in message, message


def failing_run(argv, cwd=None, stdin=None, timeout=None):
    raise review.ReviewError("gh pr view failed: offline")


def crashing_run(argv, cwd=None, stdin=None, timeout=None):
    raise TimeoutError("read timed out")


review.run = failing_run
code, message = hook("gh pr merge 5")
assert code == 2 and "could not verify" in message, message
review.run = crashing_run
code, message = hook("gh pr merge 5")
assert code == 2 and "read timed out" in message, message


def slow_run(argv, cwd=None, stdin=None, timeout=None):
    time.sleep(5)


review.GUARD_DEADLINE = 1
review.run = slow_run
code, message = hook("gh pr merge 5")
assert code == 2 and "longer than 1 seconds" in message, message
review.GUARD_DEADLINE = 90

# GH_HOST would send a gh api merge to another host than the one checked.
code, message = hook("GH_HOST=ghe.example gh api -X PUT repos/o/r/pulls/7/merge")
assert code == 2 and "only github.com" in message, message
review.run = fake_run
for command in (
    "GH_HOST=ghe.example gh pr merge 7 --repo o/r",
    "GH_REPO=other/repo gh pr merge 7",
    "gh pr merge 7 --repo ghe.example/o/r",
    "gh api --hostname=ghe.example -X PUT repos/o/r/pulls/7/merge",
    "gh api --hostname ghe.example -X PUT repos/o/r/pulls/7/merge",
    "gh api -X PUT https://ghe.example/api/v3/repos/o/r/pulls/7/merge",
):
    code, message = hook(command)
    assert code == 2 and ("only github.com" in message or "GH_HOST or GH_REPO" in message), (command, message)
assert review.review_problem(
    [f"Automated read-only review ({HEAD[:12]} on release 2026): no findings."], HEAD, "release 2026"
) is None
os.environ["GH_HOST"] = "ghe.example"
code, message = hook("gh api -X PUT repos/o/r/pulls/7/merge")
assert code == 2 and "only github.com" in message, message
del os.environ["GH_HOST"]


def late_alarm(command, cwd):
    raise TimeoutError("deadline fired late")


real_guard_check = review.guard_check
review.guard_check = late_alarm
code, message = hook("gh pr merge 5")
assert code == 2 and "deadline fired late" in message, message
review.guard_check = real_guard_check
review.run = fake_run

# Non-shell payloads are ignored.
sys.stdin = io.StringIO(json.dumps({"tool_input": {"file_path": "x"}}))
assert review.main(["guard"]) == 0
sys.stdin = io.StringIO("not json")
assert review.main(["guard"]) == 0
sys.stdin = sys.__stdin__

# Review comments must name a prefix of the head commit and the target branch.
assert review.review_problem([PINNED], HEAD, "dev") is None
assert review.review_problem([f"Automated read-only review ({HEAD[:7]} on dev): skipped (docs)."], HEAD, "dev") is None
assert "current head" in review.review_problem([STALE, "Automated read-only review: no findings."], HEAD, "dev")
assert "on main" in review.review_problem([PINNED], HEAD, "main")
assert review.review_problem(["LGTM"], HEAD, "dev") == "has no automated review comment"
assert review.review_problem([f"Automated read-only review ({HEAD[:12]} on topic(x)): no findings."], HEAD, "topic(x)") is None

# The mode follows the pinned prefix, so guards that predate it read the same target.
follow = f"Automated read-only review ({HEAD[:12]} on dev): follow-up to {'1' * 12}: fixed."
assert review.review_problem([follow], HEAD, "dev") is None and review.PINNED.match(follow)[2] == "dev"

# Changed lines count hunk lines only, including blank ones and ones that look like headers.
sample = ("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@\n context\n\n--- sql comment\n"
          "+++ added\n-old\n+new\ndiff --git a/y b/y\nBinary files a/y and b/y differ\n")
assert review.changed_lines(sample) == 4, review.changed_lines(sample)


# Forge values used in paths and refspecs must look like a commit and a branch.
def bad_forgejo(pr, path, data=None, accept="application/json"):
    return {"head": {"sha": "/tmp/victim"}, "base": {"ref": "dev"}}


review.forgejo_request = bad_forgejo
try:
    review.pr_info(review.PR("forgejo", review.FORGEJO_URL, "o", "r", "1"))
except review.ReviewError as error:
    assert "unexpected head" in str(error), error
else:
    raise AssertionError("a non-SHA head must be refused")
review.forgejo_request = fake_forgejo
assert not review.valid_branch("x:refs/heads/main") and not review.valid_branch("../x")
assert review.valid_branch("release/1.2") and review.valid_branch("release@2026") and review.valid_branch("développement")

# Reviewers do not inherit forge credentials but keep their own.
names = ["FORGEJO_TOKEN", "GITEA_TOKEN", "GH_HOST", "MY_TOKEN_FILE", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "PATH"]
env = review.reviewer_env({name: "synthetic" for name in names})
assert set(env) == {"CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "PATH"}, env.keys()

# Only an opening verdict counts, not a quoted or fenced example.
with tempfile.TemporaryDirectory() as tmp:
    reply = pathlib.Path(tmp, "reply.md")
    for text, expected in (
        ("Verdict: no findings\n", True),
        ("Reading the diff.\n\n**Verdict: non-blocking findings**\n", True),
        ("Review unavailable.\n```\nVerdict: no findings\n```\n", False),
        ("I could not read the checkout. The format was:\n  `Verdict: no findings`.\n", False),
        ("a\nb\nc\nVerdict: no findings\n", False),
        ("**Verdict:** no findings\n", True),
        ("Verdict: `blocking findings`\n", True),
        ("Verdict: unable to review\n", False),
        ("Unable to review; expected format:\n> Verdict: no findings\n", False),
        ("Unable to review.\n~~~\nVerdict: no findings\n~~~\n", False),
    ):
        reply.write_text(text)
        assert review.has_verdict(str(reply)) is expected, text

    # Reviewer names become file names.
    config_path = pathlib.Path(tmp, "config.json")
    os.environ["PR_REVIEW_CONFIG"] = str(config_path)
    for name in ("prompt", "../x", ""):
        config_path.write_text(json.dumps(
            {"timeout": 1, "reviewers": [{"name": name, "client": "codex", "model": "m", "effort": "high"}]}))
        try:
            review.load_config()
        except review.ReviewError:
            pass
        else:
            raise AssertionError(f"reviewer name {name!r} must be refused")

# Remotes and URLs resolve to a forge.
assert review.parse_remote("git@github.com:o/r.git").forge == "github"
forgejo = review.parse_remote("ssh://git@git-ssh.alc.xyz:2222/o/r.git")
assert (forgejo.forge, forgejo.host, forgejo.owner, forgejo.repo) == ("forgejo", review.FORGEJO_URL, "o", "r")
assert review.parse_remote("https://github.com/o/r").repo == "r"
assert review.parse_remote("https://codeberg.org/o/r.git") is None
pr, remote = review.resolve("https://github.com/o/r/pull/12", "/", "origin")
assert (pr.forge, pr.host, str(pr), remote) == ("github", "github.com", "o/r#12", None)
try:
    review.resolve("https://attacker.example/o/r/pull/1", "/", "origin")
except review.ReviewError as error:
    assert "only github.com" in str(error), error
else:
    raise AssertionError("GitHub PR URLs must be on github.com")
pr, _ = review.resolve("https://git.example/o/r/pulls/3/files", "/", "origin")
assert (pr.forge, pr.host, pr.number) == ("forgejo", "https://git.example", "3")

# The Forgejo token is only sent to the configured Forgejo host.
sent = []


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeOpener:
    def open(self, request, timeout):
        sent.append((request.full_url, request.get_header("Authorization")))
        return FakeResponse(b"[]")


real_opener = review.OPENER
review.OPENER = FakeOpener()
with tempfile.TemporaryDirectory() as tmp:
    token_file = pathlib.Path(tmp, "token")
    token_file.write_text("synthetic\n")
    os.environ["FORGEJO_API_TOKEN_FILE"] = str(token_file)
    real_forgejo(review.PR("forgejo", review.FORGEJO_URL, "o", "r", "1"), "issues/1/comments")
    real_forgejo(review.PR("forgejo", "https://other.example", "o", "r", "1"), "issues/1/comments")
    assert sent[0][1] == "token synthetic" and sent[1][1] is None, sent
    try:
        real_forgejo(review.PR("forgejo", "https://other.example", "o", "r", "1"), "issues/1/comments", data={})
    except review.ReviewError:
        pass
    else:
        raise AssertionError("posting to a foreign Forgejo host must fail")
    del os.environ["FORGEJO_API_TOKEN_FILE"]
review.OPENER = real_opener
assert review.NoRedirect().redirect_request(None, None, 302, "Found", {}, "https://elsewhere.example/") is None

with tempfile.TemporaryDirectory() as tmp:
    os.environ["XDG_STATE_HOME"] = os.path.join(tmp, "state")
    # A bare repository stands in for the forge; insteadOf maps the GitHub remote to it.
    forge = os.path.join(tmp, "forge.git")
    repository = os.path.join(tmp, "repo")
    git = ["git", "-c", "user.name=t", "-c", "user.email=t@example", "-C", repository]
    subprocess.run(["git", "init", "-q", "--bare", forge], check=True)
    subprocess.run(["git", "init", "-q", "-b", "dev", repository], check=True)
    subprocess.run(git + ["config", f"url.{forge}.insteadOf", "git@github.com:o/r.git"], check=True)
    subprocess.run(git + ["remote", "add", "origin", "git@github.com:o/r.git"], check=True)
    pathlib.Path(repository, "file").write_text("one\n")
    subprocess.run(git + ["add", "file"], check=True)
    subprocess.run(git + ["commit", "-qm", "init"], check=True)
    subprocess.run(git + ["push", "-q", "origin", "dev"], check=True)
    # Another clone pushes the PR head to refs/pull/4/head, so pr-review must fetch it.
    # The PR adds a line, a hook and a filtered file; neither may run during checkout.
    author = os.path.join(tmp, "author")
    subprocess.run(["git", "clone", "-q", "-b", "dev", forge, author], check=True)
    author_git = ["git", "-c", "user.name=t", "-c", "user.email=t@example", "-C", author]
    pathlib.Path(author, "file").write_text("one\n{braces} survive\n")
    hook_dir = pathlib.Path(author, "hooks")
    hook_dir.mkdir()
    pathlib.Path(hook_dir, "post-checkout").write_text(f"#!/bin/sh\ntouch {tmp}/hook-ran\n")
    os.chmod(hook_dir / "post-checkout", 0o755)
    pathlib.Path(author, ".gitattributes").write_text("file filter=probe\n")
    os.symlink("/etc/passwd", os.path.join(author, "link"))
    subprocess.run(author_git + ["add", "file", "hooks", ".gitattributes", "link"], check=True)

    def git_out(*args, stdin=None):
        return subprocess.run(author_git + list(args), input=stdin, capture_output=True, text=True, check=True).stdout.strip()

    # Git refuses to stage .git paths, so build a tree containing sub/.GIT directly.
    blob = git_out("hash-object", "-w", "--stdin", stdin="gitdir: /elsewhere\n")
    sub = git_out("mktree", stdin=f"100644 blob {blob}\t.GIT\n")
    root = git_out("ls-tree", git_out("write-tree")) + f"\n040000 tree {sub}\tsub\n"
    commit = git_out("commit-tree", git_out("mktree", stdin=root), "-p", "HEAD", "-m", "change")
    subprocess.run(author_git + ["push", "-q", "origin", f"{commit}:refs/pull/4/head"], check=True)
    head = commit
    # Hooks that fetch and update-ref would trigger, and a working-tree
    # .gitattributes that would mark the diff binary, must not take effect.
    clone_hooks = pathlib.Path(tmp, "clone-hooks")
    clone_hooks.mkdir()
    for name in ("reference-transaction", "post-checkout"):
        pathlib.Path(clone_hooks, name).write_text(f"#!/bin/sh\ntouch {tmp}/hook-ran\n")
        os.chmod(clone_hooks / name, 0o755)
    subprocess.run(git + ["config", "core.hooksPath", str(clone_hooks)], check=True)
    pathlib.Path(repository, ".gitattributes").write_text("* binary\n")
    subprocess.run(git + ["config", "filter.probe.smudge", f"touch {tmp}/filter-ran; cat"], check=True)

    # Fake reviewer CLIs: codex writes its -o file and reports its model on
    # stderr; claude prints a JSON result with per-model usage to stdout.
    bin_dir = os.path.join(tmp, "bin")
    os.mkdir(bin_dir)
    scripts = {
        "codex": 'cat >/dev/null; case "$*" in *"mcp_oauth_credentials_store=\\"file\\""*"--ignore-user-config --ignore-rules --disable apps"*) ;; *) exit 3;; esac; '
                 'test -z "$FORGEJO_API_TOKEN_FILE$GH_TOKEN" || exit 4; '
                 'printf "OpenAI Codex\\n--------\\nmodel: gpt-reported\\n--------\\nuser\\nmodel: gpt-spoofed\\n" >&2; '
                 'while [ "$1" != -o ]; do shift; done; test -f file && echo "Verdict: no findings" >"$2"',
        "claude": 'cat >/dev/null; test -f file || exit 1; test ! -L link || exit 5; test ! -e sub/.GIT || exit 7; '
                  'test "$(cat link)" = "symbolic link to /etc/passwd" || exit 6; '
                  'case "$*" in *"--restricted"*"--output-format json"*) printf \'{"result": "Reading the diff.\\\\n\\\\n**Verdict: no findings**", '
                  '"modelUsage": {"claude-helper": {"outputTokens": 3}, "claude-reported": {"outputTokens": 90}}}\';; *) exit 3;; esac',
    }
    for name, body in scripts.items():
        path = os.path.join(bin_dir, name)
        pathlib.Path(path).write_text(f"#!/bin/sh\n{body}\n")
        os.chmod(path, 0o755)
    os.environ["PATH"] = bin_dir + os.pathsep + os.environ["PATH"]
    os.environ["GH_TOKEN"] = "synthetic"

    config = {
        "timeout": 20,
        "reviewers": [
            {"name": "gpt", "client": "codex", "model": "m", "effort": "high"},
            {"name": "opus", "client": "claude", "model": "m", "effort": "high"},
        ],
    }
    os.environ["PR_REVIEW_CONFIG"] = os.path.join(tmp, "config.json")
    pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps(config))

    posted = []
    review.run = real_run
    review.pr_info = lambda pr: {"title": "t", "body": "", "head": head, "base": "dev", "url": "u"}
    review.post_comment = lambda pr, body: posted.append((str(pr), body))

    def cli(*argv):
        out, err = io.StringIO(), io.StringIO()
        sys.stdout, sys.stderr = out, err
        old = os.getcwd()
        os.chdir(repository)
        try:
            return review.main(list(argv)), out.getvalue() + err.getvalue()
        finally:
            os.chdir(old)
            sys.stdout, sys.stderr = sys.__stdout__, sys.__stderr__

    # Comments other than skips need a completed review of the current head.
    code, output = cli("comment", "4", "no findings.")
    assert code == 1 and "pr-review run 4" in output and not posted, output
    code, output = cli("comment", "4", "Automated read-only review: skipped (docs only).")
    assert code == 0 and posted[-1] == ("o/r#4", f"Automated read-only review ({head[:12]} on dev): skipped (docs only)."), posted

    # Both reviewers run against a detached checkout of the head commit.
    code, output = cli("run", "4")
    assert code == 0, output
    assert output.count("Verdict: no findings") == 2, output
    assert "Reading the diff." in output, output
    state = os.path.join(tmp, "state", "pr-review", "github.com", "o", "r", "4", head)
    status = json.loads(pathlib.Path(state, "status.json").read_text())
    assert {r["status"] for r in status["reviewers"].values()} == {"ok"}, status
    # Roles can pass aliases (ADR-0079), so the recorded model is the reported one.
    reported = {name: r["reported_model"] for name, r in status["reviewers"].items()}
    assert reported == {"gpt": "gpt-reported", "opus": "claude-helper, claude-reported"}, reported
    assert "gpt: ok" in output and "gpt-reported)" in output and "claude-helper, claude-reported)" in output, output
    prompt = pathlib.Path(state, "prompt.md").read_text()
    assert "+{braces} survive" in prompt and "+one" not in prompt, prompt
    assert not os.path.exists(os.path.join(tmp, "hook-ran")), "repository hooks must not run"
    assert not os.path.exists(os.path.join(tmp, "filter-ran")), "checkout filters must not run"
    refs = subprocess.run(git + ["for-each-ref", "refs/pr-review"], capture_output=True, text=True).stdout
    assert not refs, refs

    code, output = cli("run", "4")
    assert code == 0 and "already reviewed" in output, output
    code, output = cli("comment", "4", "no findings.")
    assert code == 0 and posted[-1][1] == f"Automated read-only review ({head[:12]} on dev): full: no findings.", posted

    # A reviewer that exits 0 without a valid verdict has not reviewed anything.
    pathlib.Path(bin_dir, "claude").write_text("#!/bin/sh\ncat >/dev/null\necho '{\"result\": \"Verdict: unable to review\"}'\n")
    code, output = cli("run", "4", "--force")
    assert code == 1 and "opus: failed" in output, output
    code, output = cli("comment", "4", "no findings.")
    assert code == 1 and "by opus;" in output, output
    # A malformed JSON result is a failed review, not a crash, and the other
    # reviewer's result is still recorded.
    pathlib.Path(bin_dir, "claude").write_text(
        "#!/bin/sh\ncat >/dev/null\necho '{\"result\": null, \"modelUsage\": {\"x\": {\"outputTokens\": null}}}'\n")
    code, output = cli("run", "4", "--force")
    assert code == 1 and "opus: failed" in output and "gpt: ok" in output, output
    status = json.loads(pathlib.Path(state, "status.json").read_text())
    assert status["reviewers"]["gpt"]["reported_model"] == "gpt-reported", status
    pathlib.Path(bin_dir, "claude").write_text("#!/bin/sh\n" + scripts["claude"] + "\n")
    code, output = cli("run", "4")
    assert code == 0, output

    # Only one run per PR head at a time.
    import fcntl
    with open(os.path.join(state, "lock"), "w") as held:
        fcntl.flock(held, fcntl.LOCK_EX)
        code, output = cli("run", "4", "--force")
    assert code == 1 and "already reviewing" in output, output
    code, output = cli("run", "4")
    assert code == 0, output

    # Retargeting the PR invalidates the earlier result.
    review.pr_info = lambda pr: {"title": "t", "body": "", "head": head, "base": "main", "url": "u"}
    code, output = cli("comment", "4", "no findings.")
    assert code == 1 and "by gpt, opus;" in output, output
    review.pr_info = lambda pr: {"title": "t", "body": "", "head": head, "base": "dev", "url": "u"}

    # The head must not move while the PR is checked out.
    heads = iter([head, "f" * 40])
    review.pr_info = lambda pr: {"title": "t", "body": "", "head": next(heads), "base": "dev", "url": "u"}
    code, output = cli("run", "4", "--force")
    assert code == 1 and "changed while it was checked out" in output, output
    review.pr_info = lambda pr: {"title": "t", "body": "", "head": head, "base": "dev", "url": "u"}
    code, output = cli("comment", "4", "no findings.")
    assert code == 1, "a forced run drops the earlier result even when it stops early"
    code, output = cli("run", "4")
    assert code == 0, output

    # A changed reviewer model invalidates the earlier result.
    config["reviewers"][1]["model"] = "m2"
    pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps(config))
    code, output = cli("comment", "4", "no findings.")
    assert code == 1 and "by opus;" in output, output

    # Failures and timeouts are reported as missing reviews, never as no findings,
    # even when a stalled reviewer never reads a prompt larger than a pipe buffer.
    review.pr_info = lambda pr: {"title": "t", "body": "x" * 300_000, "head": head, "base": "dev", "url": "u"}
    config["timeout"] = 1
    config["reviewers"][1] = {"name": "opus", "client": "codex", "model": "m", "effort": "high"}
    pathlib.Path(bin_dir, "codex").write_text("#!/bin/sh\nsleep 30\n")
    pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps(config))
    started = time.monotonic()
    code, output = cli("run", "4", "--force")
    assert time.monotonic() - started < 10, "the timeout must apply while the prompt is pending"
    assert code == 1 and "timeout" in output and "does not mean no findings" in output, output
    code, output = cli("comment", "4", "no findings.")
    assert code == 1 and "gpt, opus" in output, output

    # Follow-ups: small fixes on top of the last completed round review only the fixes.
    pathlib.Path(bin_dir, "codex").write_text("#!/bin/sh\n" + scripts["codex"] + "\n")
    pathlib.Path(bin_dir, "claude").write_text("#!/bin/sh\n" + scripts["claude"] + "\n")
    config["timeout"] = 20
    config["reviewers"][1] = {"name": "opus", "client": "claude", "model": "m", "effort": "high"}
    pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps(config))
    rounds = os.path.dirname(state)

    def at(sha, base="dev"):
        review.pr_info = lambda pr: {"title": "t", "body": "", "head": sha, "base": base, "url": "u"}

    def push(content, *parents, ref="refs/pull/4/head", files=None, extra=""):
        """Commit `file` with `content` on top of `parents`, the other files from `files`, and push it to `ref`."""
        blob = git_out("hash-object", "-w", "--stdin", stdin=content)
        listing = [line for line in git_out("ls-tree", files or parents[0]).splitlines() if not line.endswith("\tfile")]
        tree = git_out("mktree", stdin="\n".join(listing + [f"100644 blob {blob}\tfile"]) + "\n" + extra)
        sha = git_out("commit-tree", tree, *[arg for parent in parents for arg in ("-p", parent)], "-m", "c")
        subprocess.run(author_git + ["push", "-qf", "origin", f"{sha}:{ref}"], check=True)
        return sha

    def state_of(sha):
        return json.loads(pathlib.Path(rounds, sha, "status.json").read_text())

    def review_round(sha, expected, *flags, base="dev"):
        """Run on `sha` and return the mode its comment records."""
        at(sha, base)
        code, output = cli("run", "4", *flags)
        assert code == 0 and expected in output, (expected, output)
        code, output = cli("comment", "4", "no findings.")
        assert code == 0, output
        return posted[-1][1].split("): ", 1)[1].rsplit(": ", 1)[0]

    # A round from before follow-ups lacks a merge base, so the next one is full.
    at(head)
    code, output = cli("run", "4", "--force")
    assert code == 0 and "(full review: --force repeats the full review of this head)" in output, output
    status = state_of(head)
    for key in ("mode", "finished", "merge_base", "response"):
        status.pop(key, None)
    pathlib.Path(rounds, head, "status.json").write_text(json.dumps(status))
    first = push("one\n{braces} survive\nfirst\n", head)
    assert review_round(first, f"(full review: the round at {head[:12]} predates follow-ups)",
                        "--response", "kept the parser.") == "full"
    assert "## Author's response to earlier findings\n\nkept the parser." in \
        pathlib.Path(rounds, first, "prompt.md").read_text()

    # The follow-up gives every reviewer the previous findings, the response
    # and the interdiff, with the whole PR diff as context. No comment is needed
    # on the earlier round.
    fix = push("one\n{braces} survive\nfixed\n", first)
    assert review_round(fix, f"(follow-up to {first[:12]})", "--response", "fixed the parser.") \
        == f"follow-up to {first[:12]}"
    status = state_of(fix)
    assert (status["mode"], status["previous"], status["root"], status["followups"]) == ("follow-up", first, first, 1)
    prompt = pathlib.Path(rounds, fix, "prompt.md").read_text()
    assert "This is a follow-up review" in prompt and "## Author's response\n\nfixed the parser." in prompt, prompt
    assert f"### Round at {first[:12]} (full)" in prompt and "#### gpt\n\nVerdict: no findings" in prompt, prompt
    interdiff, whole = prompt.split("## Interdiff")[1].split("## Full PR diff")
    assert "+fixed" in interdiff and "+{braces}" not in interdiff and "+{braces} survive" in whole, prompt
    assert os.path.exists(pathlib.Path(rounds, head, "status.json")), "earlier rounds are kept"

    # --force on a follow-up repeats the follow-up.
    code, output = cli("run", "4", "--force", "--response", "fixed the parser.")
    assert code == 0 and f"(follow-up to {first[:12]})" in output, output

    # Later follow-ups see every round since the full review; at most
    # MAX_FOLLOW_UPS run in a row.
    for count in (2, 3):
        fix = push(f"one\n{{braces}} survive\nfixed {count}\n", fix)
        assert review_round(fix, "(follow-up to").startswith("follow-up to")
        assert (state_of(fix)["followups"], state_of(fix)["root"]) == (count, first)
    prompt = pathlib.Path(rounds, fix, "prompt.md").read_text()
    assert prompt.count("### Round at") == 3 and "Author's response before this round:\n\nfixed the parser." in prompt
    fix = push("one\n{braces} survive\nfixed 4\n", fix)
    assert review_round(fix, "(full review: 3 follow-ups in a row)") == "full"

    # --full reviews the whole PR, also again after a follow-up of the same head.
    fix = push("one\n{braces} survive\nfixed 5\n", fix)
    at(fix)
    code, output = cli("run", "4")
    assert code == 0 and state_of(fix)["mode"] == "follow-up", output
    assert review_round(fix, "(full review: --full was given)", "--full") == "full"

    # --force on a follow-up repeats it against its own round, not the latest one.
    full_round, fix = fix, push("one\n{braces} survive\nfixed 6\n", fix)
    assert review_round(fix, f"(follow-up to {full_round[:12]})") == f"follow-up to {full_round[:12]}"
    at(push("unrelated\n", fix))
    assert cli("run", "4")[0] == 0
    at(fix)
    code, output = cli("run", "4", "--force")
    assert code == 0 and f"(follow-up to {full_round[:12]})" in output, output

    # A large or binary change, a rebase, merging the target in, a retarget
    # or changed reviewers each need a full review.
    fix = push("one\n{braces} survive\n" + "more\n" * 60, fix)
    review_round(fix, "(full review: more than 40 lines changed since")
    binary = git_out("hash-object", "-w", "--stdin", stdin="\0binary\n")
    fix = push("one\n", fix, extra=f"100644 blob {binary}\tblob.bin\n")
    review_round(fix, "(full review: binary files changed since")
    dev = git_out("rev-parse", "origin/dev")
    fix = push("rebased\n", dev, files=fix)
    review_round(fix, "(full review: the head does not descend from")
    moved = push("dev moved\n", dev, ref="refs/heads/dev")
    fix = push("rebased\nmerged\n", fix, moved)
    review_round(fix, "(full review: the merge base with the target changed since")
    push("main\n", dev, ref="refs/heads/main")
    fix = push("rebased\nmerged\nretargeted\n", fix)
    review_round(fix, "(full review: no earlier completed round on main", base="main")
    # Removing a reviewer would drop its findings from the follow-up.
    removed = config["reviewers"].pop()
    pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps(config))
    fix = push("rebased\nmerged\nretargeted\nreviewers\n", fix)
    review_round(fix, "(full review: no earlier completed round on main with the current reviewers", base="main")
    # A cached follow-up by other reviewers no longer counts.
    fix = push("rebased\nmerged\nretargeted\nreviewers\nagain\n", fix)
    review_round(fix, f"(follow-up to", base="main")
    config["reviewers"].append(removed)
    pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps(config))
    code, output = cli("comment", "4", "no findings.")
    assert code == 1 and "by gpt, opus;" in output, output

    # A missing earlier round falls back to a full review.
    config["reviewers"].pop()
    pathlib.Path(os.environ["PR_REVIEW_CONFIG"]).write_text(json.dumps(config))
    os.remove(pathlib.Path(rounds, state_of(fix)["previous"], "gpt.md"))
    fix = push("rebased\nmerged\nretargeted\nreviewers\nagain\nmissing\n", fix)
    review_round(fix, "(full review: an earlier round's findings are missing since", base="main")
    # So does an earlier round that is no longer complete, deeper in the chain.
    root = fix
    fix = push("chain 1\n", root)
    review_round(fix, f"(follow-up to {root[:12]})", base="main")
    fix = push("chain 2\n", fix)
    review_round(fix, "(follow-up to", base="main")
    status = state_of(root)
    status["reviewers"]["gpt"]["status"] = "failed"
    pathlib.Path(rounds, root, "status.json").write_text(json.dumps(status))
    fix = push("chain 3\n", fix)
    review_round(fix, "(full review: an earlier round's findings are missing since", base="main")

print("pr-review tests passed")
