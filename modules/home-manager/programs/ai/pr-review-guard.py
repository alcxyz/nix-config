"""Agent PreToolUse hook: block PR merges that lack an automated review comment.

Claude Code and Codex CLI pass the pending shell command as JSON on stdin
(tool_input.command). Merges are recognised as `gh pr merge`, `gh api` calls to
GitHub's pulls/N/merge endpoint, or REST calls to a Forgejo/GitHub
.../pulls/N/merge URL. The PR must have a comment whose first line starts with
"Automated read-only review". Exit code 2 with a reason on stderr blocks the
call in both clients. Lookup failures also block: the agent should ask the
operator instead of guessing. This is an accident guard for agent sessions,
not a security boundary.
"""

import json
import os
import re
import shlex
import subprocess
import sys
import urllib.error
import urllib.request

MARKER = "automated read-only review"
FORGEJO_URL = os.environ.get("AGENT_PR_REVIEW_FORGEJO_URL", "https://git.alc.xyz")
SEPARATORS = {";", "&&", "||", "|", "&", "(", ")", "\n"}
GH_MERGE_VALUE_FLAGS = {
    "-R", "--repo", "-b", "--body", "-F", "--body-file", "-t", "--subject",
    "-A", "--author-email", "--match-head-commit",
}
API_MERGE = re.compile(
    r"(?:https?://(?P<host>[^/\s\"']+))?/*(?:api/v\d+/)?repos/"
    r"(?P<owner>[^/\s\"']+)/(?P<repo>[^/\s\"']+)/pulls/(?P<number>[^/\s\"']+)/merge\b"
)
READ_ONLY_METHOD = re.compile(r"(?:-X|--request|--method)[\s=]+[\"']?GET\b", re.IGNORECASE)
LITERAL = re.compile(r"^[A-Za-z0-9_.-]+$")

GUIDANCE = (
    "Before merging a PR you created, run independent read-only reviews with "
    "gpt-6.1-sol (high) and Claude Opus 5.5 (high). Run each sandboxed without "
    "write or forge access, and give it the diff and the PR description. Address "
    "or justify the findings, then post one PR comment whose first line starts "
    "with 'Automated read-only review:' and states the outcome, for example "
    "'Automated read-only review: no blocking findings.' For a trivial PR, post "
    "'Automated read-only review: skipped (<reason>).' Do not name models or add "
    "signatures. If the review cannot be verified, ask the operator."
)


class GuardError(Exception):
    pass


def tokenize(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()")
    lexer.whitespace_split = True
    lexer.commenters = ""
    try:
        return list(lexer)
    except ValueError:
        return command.split()


def gh_pr_merge(tokens, cwd):
    """Return (selector args, cwd) for the first `gh pr merge`, or None."""
    for index in range(len(tokens) - 2):
        if os.path.basename(tokens[index]) == "gh" and tokens[index + 1:index + 3] == ["pr", "merge"]:
            break
    else:
        return None

    for position in range(index):
        if tokens[position] == "cd" and position + 1 < index and tokens[position + 1] not in SEPARATORS:
            cwd = os.path.join(cwd, os.path.expanduser(tokens[position + 1]))

    selector, repo, args = None, None, iter(tokens[index + 3:])
    for token in args:
        if token in SEPARATORS:
            break
        name = token.split("=", 1)[0]
        if name in ("-R", "--repo"):
            repo = token.split("=", 1)[1] if "=" in token else next(args, None)
        elif token in GH_MERGE_VALUE_FLAGS:
            next(args, None)
        elif not token.startswith("-") and selector is None:
            selector = token

    view = [arg for arg in (selector,) if arg] + (["--repo", repo] if repo else [])
    return view, cwd


def run(argv, cwd):
    try:
        result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GuardError(f"{argv[0]} failed: {error}") from error
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        raise GuardError(f"{' '.join(argv[:3])} failed: {detail[-1] if detail else result.returncode}")
    return result.stdout


def reviewed(bodies):
    return any(body.lstrip().lower().startswith(MARKER) for body in bodies)


def github_bodies(argv, cwd):
    return json.loads(run(argv, cwd) or "[]")


def forgejo_bodies(base, owner, repo, number):
    token = None
    token_file = os.environ.get("FORGEJO_API_TOKEN_FILE")
    if token_file and os.path.isfile(token_file):
        with open(token_file, encoding="utf-8") as handle:
            token = handle.read().strip()
    bodies, page = [], 1
    while True:
        url = f"{base}/api/v1/repos/{owner}/{repo}/issues/{number}/comments?limit=50&page={page}"
        request = urllib.request.Request(url, headers={"Accept": "application/json"})
        if token:
            request.add_header("Authorization", f"token {token}")
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                batch = json.load(response)
        except (urllib.error.URLError, ValueError) as error:
            raise GuardError(f"cannot read comments from {base}: {error}") from error
        bodies.extend(comment.get("body", "") for comment in batch)
        if len(batch) < 50:
            return bodies
        page += 1


def check(command, cwd):
    """Return None when allowed, otherwise a reason to block."""
    if "merge" not in command:
        return None
    tokens = tokenize(command)

    found = gh_pr_merge(tokens, cwd)
    if found:
        view, view_cwd = found
        ref = "the PR (gh pr merge " + " ".join(view) + ")"
        query = '[.comments[].body]'
        bodies = github_bodies(["gh", "pr", "view", *view, "--json", "comments", "--jq", query], view_cwd)
        return None if reviewed(bodies) else f"{ref} has no automated review comment."

    match = API_MERGE.search(command)
    if not match or READ_ONLY_METHOD.search(command):
        return None
    owner, repo, number = match["owner"], match["repo"], match["number"]
    ref = f"{owner}/{repo}#{number}"
    if not all(LITERAL.match(part) for part in (owner, repo, number)) or not number.isdigit():
        return f"cannot verify {ref}: use a literal owner, repository and PR number in the merge call."

    host = match["host"]
    is_gh_api = any(
        os.path.basename(tokens[i]) == "gh" and tokens[i + 1] == "api" for i in range(len(tokens) - 1)
    )
    if is_gh_api or host == "api.github.com":
        argv = ["gh", "api", f"repos/{owner}/{repo}/issues/{number}/comments", "--paginate", "--jq", ".[].body | @json"]
        hostname = tokens.index("--hostname") + 1 if "--hostname" in tokens else 0
        if 0 < hostname < len(tokens):
            argv[2:2] = ["--hostname", tokens[hostname]]
        bodies = [json.loads(line) for line in run(argv, cwd).splitlines() if line]
    else:
        base = f"https://{host}" if host else FORGEJO_URL
        bodies = forgejo_bodies(base.rstrip("/"), owner, repo, number)
    return None if reviewed(bodies) else f"{ref} has no automated review comment."


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    command = (payload.get("tool_input") or {}).get("command")
    if not isinstance(command, str):
        return 0
    cwd = payload.get("cwd") or os.getcwd()
    try:
        reason = check(command, cwd)
    except GuardError as error:
        reason = f"could not verify the automated review: {error}."
    if reason is None:
        return 0
    print(f"Blocked by the agent PR review guard: {reason} {GUIDANCE}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
