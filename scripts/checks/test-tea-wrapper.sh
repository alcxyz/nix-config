#!/usr/bin/env bash
# Contract test for modules/home-manager/programs/tea: the wrapper drops only
# the managed --login when it has the token (#704), and activation keeps the
# managed login without touching anything else in tea's config.
set -euo pipefail

module="$(cd "$(dirname "$0")/../.." && pwd)/modules/home-manager/programs/tea"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# A fake tea that reports its arguments, one per line, and whether it got the
# environment login, never the token itself.
# The Nix build sandbox has no /usr/bin/env.
printf '#!%s\n' "$BASH" >"$work/fake-tea"
cat >>"$work/fake-tea" <<'EOF'
printf 'env:%s\n' "${GITEA_TOKEN:+set}${GITEA_INSTANCE_URL:+ $GITEA_INSTANCE_URL}"
printf 'arg:%s\n' "$@"
EOF
chmod +x "$work/fake-tea"
{
  printf '%s\n' "tea_bin=$work/fake-tea" 'tea_url=https://forge.example' 'tea_login=forge.example'
  cat "$module/tea-with-token-file.sh"
} >"$work/tea"
printf 'test-token\n' >"$work/token"

run_wrapper() {
  local token_file=$1
  shift
  FORGEJO_API_TOKEN_FILE=$token_file bash "$work/tea" "$@" 2>"$work/stderr"
}

expect() {
  local description=$1 expected=$2 actual=$3
  [[ "$actual" == "$expected" ]] || fail "$description: expected
$expected
got
$actual"
}

# T3's call shape: the managed login is dropped and the token reaches tea.
expect "managed --login" \
  "$(printf '%s\n' 'env:set https://forge.example' arg:api arg:--include arg:--repo arg:o/r arg:/user)" \
  "$(run_wrapper "$work/token" api --include --login forge.example --repo o/r /user)"
expect "managed --login=" \
  "$(printf '%s\n' 'env:set https://forge.example' arg:api arg:/user)" \
  "$(run_wrapper "$work/token" api --login=forge.example /user)"
expect "managed -l" \
  "$(printf '%s\n' 'env:set https://forge.example' arg:pulls arg:ls)" \
  "$(run_wrapper "$work/token" pulls -l forge.example ls)"

# Another login, or one after --, is passed through.
expect "other login" \
  "$(printf '%s\n' 'env:set https://forge.example' arg:api arg:--login arg:other arg:/user)" \
  "$(run_wrapper "$work/token" api --login other /user)"
expect "after --" \
  "$(printf '%s\n' 'env:set https://forge.example' arg:api arg:-- arg:--login arg:forge.example)" \
  "$(run_wrapper "$work/token" api -- --login forge.example)"
expect "trailing --login" \
  "$(printf '%s\n' 'env:set https://forge.example' arg:api arg:--login)" \
  "$(run_wrapper "$work/token" api --login)"

# Without the token, the stored login keeps working as named.
expect "no token file" \
  "$(printf '%s\n' 'env:' arg:api arg:--login arg:forge.example arg:/user)" \
  "$(run_wrapper "" api --login forge.example /user)"
# A named token file that yields no token fails closed: neither stored logins
# nor an inherited GITEA_TOKEN stand in for it (#722).
: >"$work/empty-token"
printf ' \n' >"$work/blank-token"
printf 'test-token\n' >"$work/unreadable-token"
chmod 000 "$work/unreadable-token"
for bad in "$work/empty-token" "$work/blank-token" "$work/missing-token" "$work/unreadable-token" "$work"; do
  [[ $bad != "$work/unreadable-token" || ! -r $bad ]] || continue # root can read it
  status=0
  output=$(GITEA_TOKEN=inherited run_wrapper "$bad" api --login forge.example) || status=$?
  [[ $status == 1 && -z $output ]] || fail "unusable token file $bad: exit $status, output $output"
  grep -q "no token in $bad" "$work/stderr" || fail "unusable token file $bad was not reported"
done
chmod 600 "$work/unreadable-token"
if grep -rq test-token "$work/stderr"; then
  fail "the wrapper printed the token"
fi

# Activation: the managed login is added or updated, and nothing else changes.
{
  printf '%s\n' 'tea_url=https://forge.example' 'tea_login=forge.example' 'tea_ssh_host=ssh.forge.example' \
    "tea_config_home='Library/Application Support'"
  cat "$module/ensure-login.sh"
} >"$work/ensure-login"
ensure() {
  XDG_CONFIG_HOME="$work/config" HOME="$work/home" bash "$work/ensure-login"
}
config="$work/config/tea/config.yml"
login_field() {
  yq -r ".logins[] | select(.name == \"$1\") | .$2" "$config"
}

ensure >/dev/null
[[ "$(stat -c %a "$config")" == 600 ]] || fail "new config is not private"
[[ "$(yq -r '.logins | length' "$config")" == 1 ]] || fail "new config does not hold one login"
[[ "$(login_field forge.example url)" == https://forge.example ]] || fail "managed login has the wrong URL"
[[ "$(login_field forge.example ssh_host)" == ssh.forge.example ]] || fail "managed login has the wrong SSH host"
[[ "$(login_field forge.example token)" == null ]] || fail "activation added a token"

cat >"$config" <<'EOF'
logins:
  - name: other
    url: https://other.example
    token: other-token
    default: true
  - name: forge.example
    url: https://forge.example
    ssh_host: forge.example
    user: someone
preferences:
  editor: true
EOF
ensure >/dev/null
[[ "$(login_field forge.example ssh_host)" == ssh.forge.example ]] || fail "SSH host was not updated"
[[ "$(login_field forge.example user)" == someone ]] || fail "managed login lost its user"
[[ "$(login_field other token)" == other-token ]] || fail "another login lost its token"
[[ "$(login_field other default)" == true ]] || fail "another login lost its default"
[[ "$(yq -r '.preferences.editor' "$config")" == true ]] || fail "preferences were lost"
[[ "$(yq -r '.logins | length' "$config")" == 2 ]] || fail "logins were added or removed"

before=$(stat -c %Y.%i "$config")
output=$(ensure)
[[ -z "$output" ]] || fail "unchanged config was reported: $output"
[[ "$(stat -c %Y.%i "$config")" == "$before" ]] || fail "unchanged config was rewritten"

# A config linked from elsewhere is left alone.
mv "$config" "$work/linked.yml"
ln -s "$work/linked.yml" "$config"
ensure 2>/dev/null
[[ -L "$config" ]] || fail "linked config was replaced"
shopt -s nullglob dotglob
leftovers=("$work/config/tea"/.config.yml.*)
((${#leftovers[@]} == 0)) || fail "temporary files were left behind: ${leftovers[*]}"

# Without XDG_CONFIG_HOME, the platform's config home is used ...
XDG_CONFIG_HOME='' HOME="$work/mac" bash "$work/ensure-login" >/dev/null
[[ -f "$work/mac/Library/Application Support/tea/config.yml" ]] || fail "the platform config home was not used"

# ... unless only tea's legacy config exists, which is updated instead.
mkdir -p "$work/legacy/.tea"
printf 'logins:\n  - name: other\n    url: https://other.example\n' >"$work/legacy/.tea/tea.yml"
XDG_CONFIG_HOME='' HOME="$work/legacy" bash "$work/ensure-login" >/dev/null
[[ ! -e "$work/legacy/Library/Application Support/tea/config.yml" ]] || fail "a new config shadows the legacy one"
[[ "$(yq -r '.logins | length' "$work/legacy/.tea/tea.yml")" == 2 ]] || fail "the legacy config did not get the login"

echo "tea wrapper contract: ok"
