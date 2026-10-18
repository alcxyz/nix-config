#!/usr/bin/env bash
# Contract test for the agent pre-push hook (ADR-0078): with a GitHub
# fast-forward repository listed, the user's Git configuration registers
# `pr-review pre-push`, T3 Code's session wrapper marks agent sessions with
# PR_REVIEW_AGENT_SESSION=1, and Git runs the hook, which refuses what it can
# decide without network in agent processes: deleting `main` of the listed
# repository. Tags, unlisted URLs and the operator's own pushes pass.
#
# Usage: test-agent-pr-review-hook.sh WRAPPER GIT_CONFIG LISTED_URL
set -euo pipefail

wrapper=$1 git_config=$2 listed_url=$3
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

export HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config"
export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=$git_config
mkdir -p "$HOME" "$work/no-hooks"
unset GIT_CONFIG_COUNT PR_REVIEW_AGENT_SESSION CLAUDECODE CODEX_THREAD_ID CODEX_TOOL_CALL_ID CODEX_SANDBOX_NETWORK_DISABLED

: >"$work/session-vars.sh"
# shellcheck disable=SC2016 # expanded inside the agent session
marker=$(T3CODE_SESSION_VARS="$work/session-vars.sh" "$wrapper" bash -c 'echo "${PR_REVIEW_AGENT_SESSION-}"')
[[ $marker == 1 ]] || fail "the session wrapper does not mark agent sessions: '$marker'"

git init -q -b main "$work/repo"
cd "$work/repo"
git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m init
head=$(git rev-parse HEAD)

command=$(git config --get hook.agent-pr-review.command)
[[ $command == /nix/store/*/bin/pr-review\ pre-push ]] || fail "hook command: $command"
[[ $(git config --get hook.agent-pr-review.event) == pre-push ]] || fail "hook event"
git hook list pre-push | grep -qx agent-pr-review || fail "Git does not list the hook"

zero=0000000000000000000000000000000000000000
run_hook() {
  printf '%s\n' "$1" >"$work/stdin"
  # The repository's script hooks (core.hooksPath) are not under test.
  git -c core.hooksPath="$work/no-hooks" hook run --to-stdin="$work/stdin" pre-push -- origin "$2"
}

export PR_REVIEW_AGENT_SESSION=1
if run_hook "(delete) $zero refs/heads/main $head" "$listed_url" 2>"$work/err"; then
  fail "the hook let a deletion of main through"
fi
grep -qF "deleting its protected branch main" "$work/err" || fail "unexpected refusal: $(cat "$work/err")"
run_hook "refs/tags/v1 $head refs/tags/v1 $zero" "$listed_url" || fail "the hook refused a tag"
run_hook "(delete) $zero refs/heads/main $head" "https://github.com/someone-else/repo.git" ||
  fail "the hook refused an unlisted repository"
unset PR_REVIEW_AGENT_SESSION
run_hook "(delete) $zero refs/heads/main $head" "$listed_url" || fail "the hook checked the operator's own push"
echo "agent pre-push hook contract passed"
