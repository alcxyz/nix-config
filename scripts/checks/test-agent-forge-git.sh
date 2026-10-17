#!/usr/bin/env bash
# Contract test for programs.ai.agentForge (#722): T3 Code's session wrapper
# gives agent sessions the agent account's API token file, sends their Git
# pushes to the forge over HTTPS, and lets Git ask only the agent account's
# credential helper there. No network: push URLs come from
# `git remote get-url --push` and credentials from `git credential fill`.
#
# Usage: test-agent-forge-git.sh WRAPPER URL SSH_HOST USER TOKEN_FILE
# The wrapper's forge-mirror must run "$AGENT_FORGE_TEST_HELPER" instead.
set -euo pipefail

wrapper=$1 url=$2 ssh_host=$3 user=$4 token_file=$5
host=${url#https://}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect() {
  local description=$1 expected=$2 actual=$3
  [[ "$actual" == "$expected" ]] || fail "$description: expected
$expected
got
$actual"
}

export HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config"
export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=false SSH_ASKPASS=false
mkdir -p "$HOME"
unset GIT_CONFIG_COUNT FORGEJO_TOKEN FORGEJO_TOKEN_FILE FORGEJO_USER

# Fake credential helpers record their calls and answer with dummy values.
# The Nix build sandbox has no /usr/bin/env.
export AGENT_FORGE_TEST_LOG="$work/helpers.log"
printf '#!%s\n' "$BASH" >"$work/agent-helper"
cat >>"$work/agent-helper" <<'EOF'
printf 'agent args=%s user=%s token_file=%s token=[%s]\n' "$*" "$FORGEJO_USER" "$FORGEJO_TOKEN_FILE" "${FORGEJO_TOKEN-unset}" >>"$AGENT_FORGE_TEST_LOG"
if [[ "$*" == "credential-helper get" ]]; then
  printf 'username=%s\npassword=agent-dummy\n' "$FORGEJO_USER"
fi
EOF
printf '#!%s\n' "$BASH" >"$work/operator-helper"
cat >>"$work/operator-helper" <<'EOF'
printf 'operator %s\n' "$*" >>"$AGENT_FORGE_TEST_LOG"
if [[ "${*: -1}" == get ]]; then
  printf 'username=operator\npassword=operator-dummy\n'
fi
EOF
chmod +x "$work/agent-helper" "$work/operator-helper"
export AGENT_FORGE_TEST_HELPER="$work/agent-helper"

# The operator's global configuration: a helper for every host and one for
# the forge, as login shells have them.
git config --global credential.helper "!$work/operator-helper all"
git config --global "credential.$url.helper" "!$work/operator-helper forge"

# Session variables that point at the operator's token, which the wrapper
# must override for agent sessions.
printf 'export FORGEJO_API_TOKEN_FILE=%q FORGEJO_TOKEN_FILE=%q FORGEJO_USER=operator FORGEJO_TOKEN=session-dummy\n' \
  "$work/operator-token" "$work/operator-token" >"$work/session-vars.sh"

agent() {
  T3CODE_SESSION_VARS="$work/session-vars.sh" "$wrapper" "$@"
}

expect "agent API token file" "$token_file" "$(agent printenv FORGEJO_API_TOKEN_FILE)"
# forge-mirror's own API calls authenticate as the account, while its
# namespace stays the operator's.
expect "agent forge-mirror token file" "$token_file" "$(agent printenv FORGEJO_TOKEN_FILE)"
expect "forge-mirror namespace" "operator" "$(agent printenv FORGEJO_USER)"
# shellcheck disable=SC2016 # expanded inside the agent session
expect "session token value" "unset" "$(agent bash -c 'echo "${FORGEJO_TOKEN-unset}"')"
# Configuration already passed through the environment is kept.
expect "existing GIT_CONFIG entries" "kept" \
  "$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=test.agentforge GIT_CONFIG_VALUE_0=kept agent git config test.agentforge)"

repo() {
  local name=$1 origin=$2
  git init -q "$work/$name"
  git -C "$work/$name" remote add origin "$origin"
}

# An SSH origin, in both SSH forms: pushes go over HTTPS, fetches keep SSH.
repo scp "git@$ssh_host:owner/repo.git"
expect "operator push URL (scp form)" "git@$ssh_host:owner/repo.git" "$(git -C "$work/scp" remote get-url --push origin)"
expect "agent push URL (scp form)" "$url/owner/repo.git" "$(agent git -C "$work/scp" remote get-url --push origin)"
expect "agent fetch URL (scp form)" "git@$ssh_host:owner/repo.git" "$(agent git -C "$work/scp" remote get-url origin)"
repo ssh "ssh://git@$ssh_host/owner/repo.git"
expect "agent push URL (ssh form)" "$url/owner/repo.git" "$(agent git -C "$work/ssh" remote get-url --push origin)"

# An HTTPS origin under a host-wide insteadOf that sends HTTPS to SSH: the
# operator pushes over SSH, the agent over HTTPS.
repo https "$url/owner/repo.git"
git config --global "url.ssh://git@$ssh_host/.insteadOf" "$url/"
expect "operator push URL (host-wide insteadOf)" "ssh://git@$ssh_host/owner/repo.git" "$(git -C "$work/https" remote get-url --push origin)"
expect "agent push URL (host-wide insteadOf)" "$url/owner/repo.git" "$(agent git -C "$work/https" remote get-url --push origin)"
# Limit (ADR-0081): an explicit push URL is not rewritten by pushInsteadOf,
# but insteadOf rewrites it, so an HTTPS one under the host-wide rule pushes
# over SSH as the operator.
git -C "$work/https" config remote.origin.pushurl "$url/owner/repo.git"
expect "agent explicit HTTPS push URL (host-wide insteadOf)" "ssh://git@$ssh_host/owner/repo.git" "$(agent git -C "$work/https" remote get-url --push origin)"
git -C "$work/https" config --unset remote.origin.pushurl
git config --global --unset "url.ssh://git@$ssh_host/.insteadOf"

# Only the agent account's helper answers for the forge, with the token file
# and user from the configuration and without a token value in the environment.
: >"$AGENT_FORGE_TEST_LOG"
credentials=$(printf 'protocol=https\nhost=%s\npath=owner/repo.git\n\n' "$host" | agent git credential fill)
expect "agent credentials" "protocol=https
host=$host
username=$user
password=agent-dummy" "$credentials"
expect "helpers asked for the forge" "agent args=credential-helper get user=$user token_file=$token_file token=[]" "$(cat "$AGENT_FORGE_TEST_LOG")"

# FORGEJO_TOKEN in the session never reaches the helper.
: >"$AGENT_FORGE_TEST_LOG"
printf 'protocol=https\nhost=%s\n\n' "$host" | FORGEJO_TOKEN=session-dummy agent git credential fill >/dev/null
expect "helper without session token" "agent args=credential-helper get user=$user token_file=$token_file token=[]" "$(cat "$AGENT_FORGE_TEST_LOG")"

# Precedence (ADR-0081): an operator-level pushInsteadOf with the same prefix
# is read first and wins the tie, so the push stays on SSH.
git config --global "url.ssh://git@$ssh_host/.pushInsteadOf" "$url/"
expect "agent push URL (operator pushInsteadOf)" "ssh://git@$ssh_host/owner/repo.git" "$(agent git -C "$work/https" remote get-url --push origin)"
git config --global --unset "url.ssh://git@$ssh_host/.pushInsteadOf"
# Helpers for more specific URLs (a path or a user) in the configuration
# files are read earlier and reset too.
git config --global "credential.$url/owner/repo.git.helper" "!$work/operator-helper path"
git config --global "credential.https://someone@$host.helper" "!$work/operator-helper user"
for request in "path=owner/repo.git" "username=someone"; do
  : >"$AGENT_FORGE_TEST_LOG"
  printf 'protocol=https\nhost=%s\n%s\n\n' "$host" "$request" | agent git credential fill >/dev/null
  expect "helpers asked for $request" "agent args=credential-helper get user=$user token_file=$token_file token=[]" "$(cat "$AGENT_FORGE_TEST_LOG")"
done
git config --global --unset "credential.$url/owner/repo.git.helper"
git config --global --unset "credential.https://someone@$host.helper"

# Other hosts keep the operator's helpers.
: >"$AGENT_FORGE_TEST_LOG"
printf 'protocol=https\nhost=other.example.invalid\n\n' | agent git credential fill >/dev/null
expect "helpers asked for another host" "operator all get" "$(cat "$AGENT_FORGE_TEST_LOG")"

echo "agent forge Git environment: push URLs and credential helpers passed"
