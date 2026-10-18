#!/usr/bin/env bash
# Contract test for programs.ai.agentGithub (ADR-0099): T3 Code's session
# wrapper sets the App's variables for gh-app's pass-through `gh`, sends Git
# pushes to the owner's GitHub repositories over HTTPS, and asks the App's
# credential helper first and the operator's gh login second for github.com.
# No network: push URLs come from `git remote get-url --push` and credentials
# from `git credential fill`.
#
# Usage: test-agent-github-git.sh WRAPPER OWNER APP_ID KEY_FILE
# The wrapper's gh-app must run "$AGENT_GITHUB_TEST_APP" and its gh
# "$AGENT_GITHUB_TEST_GH".
set -euo pipefail

wrapper=$1 owner=$2 app_id=$3 key_file=$4
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
unset GIT_CONFIG_COUNT GH_AS_OPERATOR GH_APP_ID GH_APP_KEY_FILE GH_APP_OWNER

# Fakes record their calls. The App's helper answers only for a repository
# named "installed", as the real one answers only for installed repositories.
# The Nix build sandbox has no /usr/bin/env.
export AGENT_GITHUB_TEST_LOG="$work/calls.log"
printf '#!%s\n' "$BASH" >"$work/fake-app"
cat >>"$work/fake-app" <<'EOF'
printf 'app args=%s id=%s key=%s owner=%s\n' "$*" "$GH_APP_ID" "$GH_APP_KEY_FILE" "$GH_APP_OWNER" >>"$AGENT_GITHUB_TEST_LOG"
if [[ "$*" == "credential get" ]]; then
  request=$(cat)
  if [[ "$request" == *"path=$GH_APP_OWNER/installed"* ]]; then
    printf 'username=x-access-token\npassword=app-dummy\n'
  elif [[ "$request" == *"path=$GH_APP_OWNER/unmintable"* ]]; then
    printf 'quit=1\n'
  fi
fi
EOF
printf '#!%s\n' "$BASH" >"$work/fake-gh"
cat >>"$work/fake-gh" <<'EOF'
printf 'gh %s\n' "$*" >>"$AGENT_GITHUB_TEST_LOG"
if [[ "$*" == "auth git-credential get" ]]; then
  printf 'username=operator\npassword=operator-dummy\n'
fi
EOF
printf '#!%s\n' "$BASH" >"$work/operator-helper"
cat >>"$work/operator-helper" <<'EOF'
printf 'operator %s\n' "$*" >>"$AGENT_GITHUB_TEST_LOG"
if [[ "${*: -1}" == get ]]; then
  printf 'username=operator\npassword=operator-dummy\n'
fi
EOF
chmod +x "$work/fake-app" "$work/fake-gh" "$work/operator-helper"
export AGENT_GITHUB_TEST_APP="$work/fake-app" AGENT_GITHUB_TEST_GH="$work/fake-gh"

# The operator's global configuration: a helper for every host and one for
# github.com, as login shells may have them.
git config --global credential.helper "!$work/operator-helper all"
git config --global credential.https://github.com.helper "!$work/operator-helper github"

: >"$work/session-vars.sh"
agent() {
  T3CODE_SESSION_VARS="$work/session-vars.sh" "$wrapper" "$@"
}

# The session carries the App's settings for gh-app's pass-through `gh`.
# shellcheck disable=SC2016 # expanded inside the agent session
expect "App settings" "$app_id $key_file $owner" "$(agent bash -c 'echo "$GH_APP_ID $GH_APP_KEY_FILE $GH_APP_OWNER"')"
# Configuration already passed through the environment is kept.
expect "existing GIT_CONFIG entries" "kept" \
  "$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=test.agentgithub GIT_CONFIG_VALUE_0=kept agent git config test.agentgithub)"

repo() {
  local name=$1 origin=$2
  git init -q "$work/$name"
  git -C "$work/$name" remote add origin "$origin"
}

# The owner's SSH remotes push over HTTPS and fetch over SSH; other owners
# keep their transport.
repo scp "git@github.com:$owner/installed.git"
expect "operator push URL (scp form)" "git@github.com:$owner/installed.git" "$(git -C "$work/scp" remote get-url --push origin)"
expect "agent push URL (scp form)" "https://github.com/$owner/installed.git" "$(agent git -C "$work/scp" remote get-url --push origin)"
expect "agent fetch URL (scp form)" "git@github.com:$owner/installed.git" "$(agent git -C "$work/scp" remote get-url origin)"
repo ssh "ssh://git@github.com/$owner/installed.git"
expect "agent push URL (ssh form)" "https://github.com/$owner/installed.git" "$(agent git -C "$work/ssh" remote get-url --push origin)"
# An HTTPS origin under a host-wide insteadOf that sends HTTPS to SSH: the
# agent still pushes over HTTPS.
repo https "https://github.com/$owner/installed.git"
git config --global url.git@github.com:.insteadOf https://github.com/
expect "agent push URL (host-wide insteadOf)" "https://github.com/$owner/installed.git" "$(agent git -C "$work/https" remote get-url --push origin)"
git config --global --unset url.git@github.com:.insteadOf
repo other "git@github.com:someone-else/repo.git"
expect "agent push URL (other owner)" "git@github.com:someone-else/repo.git" "$(agent git -C "$work/other" remote get-url --push origin)"

credentials() {
  printf 'protocol=https\nhost=github.com\npath=%s\n\n' "$1" | agent git credential fill
}

# An installed repository gets the App's token; the operator's helpers for
# github.com are reset and not asked.
: >"$AGENT_GITHUB_TEST_LOG"
expect "agent credentials (installed)" "protocol=https
host=github.com
path=$owner/installed.git
username=x-access-token
password=app-dummy" "$(credentials "$owner/installed.git")"
expect "helpers asked (installed)" "app args=credential get id=$app_id key=$key_file owner=$owner" "$(cat "$AGENT_GITHUB_TEST_LOG")"

# Anything else falls through to the operator's gh login.
: >"$AGENT_GITHUB_TEST_LOG"
expect "agent credentials (not installed)" "protocol=https
host=github.com
path=someone-else/repo.git
username=operator
password=operator-dummy" "$(credentials someone-else/repo.git)"
expect "helpers asked (not installed)" "app args=credential get id=$app_id key=$key_file owner=$owner
gh auth git-credential get" "$(cat "$AGENT_GITHUB_TEST_LOG")"

# When the App cannot get a token for an owner repository, Git stops rather
# than asking the operator's login.
: >"$AGENT_GITHUB_TEST_LOG"
if credentials "$owner/unmintable.git" >/dev/null 2>&1; then
  fail "Git fell back after the App's helper said quit"
fi
expect "helpers asked (quit)" "app args=credential get id=$app_id key=$key_file owner=$owner" "$(cat "$AGENT_GITHUB_TEST_LOG")"

# Other hosts keep the operator's helpers.
: >"$AGENT_GITHUB_TEST_LOG"
printf 'protocol=https\nhost=other.example.invalid\n\n' | agent git credential fill >/dev/null
expect "helpers asked for another host" "operator all get" "$(cat "$AGENT_GITHUB_TEST_LOG")"

echo "agent GitHub environment: gh shim, push URLs and credential helpers passed"
