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

    # Fake reviewer CLIs: codex writes its -o file, claude prints to stdout.
    bin_dir = os.path.join(tmp, "bin")
    os.mkdir(bin_dir)
    scripts = {
        "codex": 'cat >/dev/null; case "$*" in *"--ignore-user-config --ignore-rules --disable apps"*) ;; *) exit 3;; esac; '
                 'test -z "$FORGEJO_API_TOKEN_FILE$GH_TOKEN" || exit 4; '
                 'while [ "$1" != -o ]; do shift; done; test -f file && echo "Verdict: no findings" >"$2"',
        "claude": 'cat >/dev/null; test -f file || exit 1; test ! -L link || exit 5; test ! -e sub/.GIT || exit 7; '
                  'test "$(cat link)" = "symbolic link to /etc/passwd" || exit 6; '
                  'case "$*" in *--restricted*) printf "Reading the diff.\\n\\n**Verdict: no findings**\\n";; *) exit 3;; esac',
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
    prompt = pathlib.Path(state, "prompt.md").read_text()
    assert "+{braces} survive" in prompt and "+one" not in prompt, prompt
    assert not os.path.exists(os.path.join(tmp, "hook-ran")), "repository hooks must not run"
    assert not os.path.exists(os.path.join(tmp, "filter-ran")), "checkout filters must not run"
    refs = subprocess.run(git + ["for-each-ref", "refs/pr-review"], capture_output=True, text=True).stdout
    assert not refs, refs

    code, output = cli("run", "4")
    assert code == 0 and "already reviewed" in output, output
    code, output = cli("comment", "4", "no findings.")
    assert code == 0 and posted[-1][1] == f"Automated read-only review ({head[:12]} on dev): no findings.", posted

    # A reviewer that exits 0 without a valid verdict has not reviewed anything.
    pathlib.Path(bin_dir, "claude").write_text("#!/bin/sh\ncat >/dev/null\necho \"Verdict: unable to review\"\n")
    code, output = cli("run", "4", "--force")
    assert code == 1 and "opus: failed" in output, output
    code, output = cli("comment", "4", "no findings.")
    assert code == 1 and "by opus;" in output, output
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

print("pr-review tests passed")
