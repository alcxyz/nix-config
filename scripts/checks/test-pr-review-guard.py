"""Contract tests for the agent PR review guard hook."""

import importlib.util
import io
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "guard", ROOT / "modules/home-manager/programs/ai/pr-review-guard.py"
)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

REVIEWED = ["LGTM", "Automated read-only review: no blocking findings."]
calls = []


def fake_run(argv, cwd):
    calls.append((argv, cwd))
    joined = " ".join(argv)
    bodies = REVIEWED if "reviewed" in joined or "7" in argv or "/7/" in joined else ["LGTM"]
    if argv[1] == "api":
        return "\n".join(json.dumps(body) for body in bodies)
    return json.dumps(bodies)


def fake_forgejo(base, owner, repo, number):
    calls.append((base, owner, repo, number))
    return REVIEWED if number == "7" else ["Automated review pending"]


guard.run = fake_run
guard.forgejo_bodies = fake_forgejo


def hook(command, cwd="/work"):
    sys.stdin = io.StringIO(json.dumps({"tool_input": {"command": command}, "cwd": cwd}))
    sys.stderr = io.StringIO()
    try:
        return guard.main(), sys.stderr.getvalue()
    finally:
        sys.stdin, sys.stderr = sys.__stdin__, sys.__stderr__


def expect(command, status, cwd="/work"):
    calls.clear()
    code, message = hook(command, cwd)
    assert code == status, f"{command!r}: expected {status}, got {code}: {message}"
    if status == 2:
        assert "Automated read-only review:" in message, message
    return calls


# Unrelated commands and non-merge calls pass without lookups.
assert not expect("git merge origin/main", 0)
assert not expect("gh pr view 5", 0)
assert not expect("echo hello", 0)

# gh pr merge resolves selector, repository and cwd for gh pr view.
seen = expect("gh pr merge 5 --squash --body 'x y' -R owner/repo", 2)
assert seen[0][0][:6] == ["gh", "pr", "view", "5", "--repo", "owner/repo"], seen
seen = expect("cd sub && gh pr merge 7 --squash", 0)
assert seen[0][1] == "/work/sub", seen
expect("gh pr merge --repo=owner/reviewed --squash", 0)

# GitHub API and Forgejo REST merges.
expect("gh api -X PUT repos/o/r/pulls/7/merge -f merge_method=squash", 0)
expect("gh api -X PUT repos/o/r/pulls/8/merge", 2)
seen = expect("curl -X POST https://git.example/api/v1/repos/o/r/pulls/7/merge -d '{}'", 0)
assert seen[0][0] == "https://git.example", seen
expect('curl -X POST "$FORGEJO/api/v1/repos/o/r/pulls/8/merge"', 2)
expect("curl --request GET https://git.example/api/v1/repos/o/r/pulls/8/merge", 0)

# Unresolvable merge targets block with guidance.
code, message = hook('curl -X POST https://git.example/api/v1/repos/o/r/pulls/$PR/merge')
assert code == 2 and "literal owner" in message, message


def failing_run(argv, cwd):
    raise guard.GuardError("gh pr view failed: offline")


guard.run = failing_run
code, message = hook("gh pr merge 5")
assert code == 2 and "could not verify" in message, message

# Non-shell payloads are ignored.
sys.stdin = io.StringIO(json.dumps({"tool_input": {"file_path": "x"}}))
assert guard.main() == 0
sys.stdin = io.StringIO("not json")
assert guard.main() == 0

print("PR review guard tests passed")
