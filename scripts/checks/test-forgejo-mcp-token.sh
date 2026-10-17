#!/usr/bin/env bash
# Contract test for the forgejo-mcp-agent wrapper (ADR-0081, #722): the
# session's FORGEJO_API_TOKEN_FILE chooses the token, the configured tokenFile
# serves sessions without it, and a named file that yields no token fails
# instead of falling back. forgejo-mcp is replaced by a fake that prints the
# dummy token it got.
#
# Usage: test-forgejo-mcp-token.sh WRAPPER
# The wrapper's configured tokenFile must be the relative path fallback-token.
set -euo pipefail

wrapper=$1
work=$(mktemp -d)
trap 'chmod -R u+rw -- "$work"; rm -rf -- "$work"' EXIT
cd "$work"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# shellcheck disable=SC2016 # the fake's variable must reach the copy literally
sed 's#^exec forgejo-mcp #exec "$FAKE_MCP" #' "$wrapper" >mcp
grep -q FAKE_MCP mcp || fail "the wrapper does not exec forgejo-mcp"
chmod +x mcp
# The Nix build sandbox has no /usr/bin/env.
# shellcheck disable=SC2016 # expanded by the fake, not here
printf '#!%s\nprintf "%%s\\n" "$FORGEJO_ACCESS_TOKEN"\n' "$BASH" >fake-mcp
chmod +x fake-mcp
export FAKE_MCP=$work/fake-mcp
printf 'session-dummy\n' >session-token
printf 'fallback-dummy\n' >fallback-token

run() {
  status=0
  output=$(./mcp 2>"$work/stderr") || status=$?
}

FORGEJO_API_TOKEN_FILE=$work/session-token run
[[ $status == 0 && $output == session-dummy ]] || fail "session token file not used: $status $output"

unset FORGEJO_API_TOKEN_FILE
run
[[ $status == 0 && $output == fallback-dummy ]] || fail "tokenFile not used without the variable: $status $output"

: >empty-token
printf ' \n' >blank-token
printf 'session-dummy\n' >unreadable-token
chmod 000 unreadable-token
mkdir directory-token
for bad in "$work/missing-token" "$work/empty-token" "$work/blank-token" "$work/unreadable-token" "$work/directory-token"; do
  [[ $bad != "$work/unreadable-token" || ! -r $bad ]] || continue # root can read it
  FORGEJO_API_TOKEN_FILE=$bad run
  [[ $status == 1 && -z $output ]] || fail "unusable token file $bad: exit $status, output $output"
  grep -qF "$bad" stderr || fail "unusable token file $bad was not reported"
done

rm fallback-token
run
[[ $status == 1 && -z $output ]] || fail "missing tokenFile: exit $status, output $output"

echo "forgejo-mcp-agent token selection: ok"
