#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo_root/modules/home-manager/programs/ai/merge-settings.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

printf '%s\n' '{"statusLine":{"type":"command","command":"managed"}}' >"$fixture/managed.json"
settings="$fixture/home/.claude/settings.json"
merge() { bash "$script" "$settings" "$fixture/managed.json"; }

# Missing settings are initialized privately.
merge
jq -e '.statusLine.command == "managed"' "$settings" >/dev/null
[ "$(stat -c '%a' "$settings")" = 600 ] || fail 'settings mode is not 600'

# Existing user fields survive; managed fields take precedence.
printf '%s\n' '{"theme":"dark","statusLine":{"command":"old","padding":2}}' >"$settings"
merge
jq -e '.theme == "dark" and .statusLine.command == "managed" and .statusLine.padding == 2' "$settings" >/dev/null

# Managed hooks are added beside user hooks, replace a user copy of the same
# command, and stay single across repeated merges.
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard","timeout":60}]}]}}' >"$fixture/managed-hooks.json"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"secrets"}]},{"matcher":"Bash","hooks":[{"type":"command","command":"guard","timeout":5}]}],"Stop":[{"hooks":[{"type":"command","command":"stop"}]}]}}' >"$settings"
bash "$script" "$settings" "$fixture/managed-hooks.json"
bash "$script" "$settings" "$fixture/managed-hooks.json"
jq -e '
  [.hooks.PreToolUse[].hooks[].command] == ["secrets", "guard"]
  and .hooks.PreToolUse[1].hooks[0].timeout == 60
  and .hooks.Stop[0].hooks[0].command == "stop"
' "$settings" >/dev/null || fail 'managed hooks were not combined with user hooks'

# Managed permission rules are added to the user's without duplicates, and an
# empty managed list keeps the user's rules.
printf '%s\n' '{"permissions":{"allow":["mcp__x__read","mcp__x__list"]}}' >"$fixture/managed-permissions.json"
printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)","mcp__x__read"],"deny":["Bash(sops -d:*)"],"defaultMode":"default"}}' >"$settings"
bash "$script" "$settings" "$fixture/managed-permissions.json"
bash "$script" "$settings" "$fixture/managed-permissions.json"
jq -e '
  .permissions.allow == ["Bash(ls:*)", "mcp__x__read", "mcp__x__list"]
  and .permissions.deny == ["Bash(sops -d:*)"]
  and .permissions.defaultMode == "default"
' "$settings" >/dev/null || fail 'managed permissions were not combined with user permissions'
printf '%s\n' '{"permissions":{"allow":[]}}' >"$fixture/managed-permissions.json"
bash "$script" "$settings" "$fixture/managed-permissions.json"
jq -e '.permissions.allow == ["Bash(ls:*)", "mcp__x__read", "mcp__x__list"]' "$settings" >/dev/null ||
  fail 'an empty managed rule list replaced user rules'

# Malformed, empty, non-object, and multiple JSON documents must be preserved.
for content in '{broken' '' '[]' 'null' '{} {}'; do
  printf '%s' "$content" >"$settings"
  cp "$settings" "$fixture/before"
  if merge >"$fixture/output" 2>&1; then fail 'invalid settings accepted'; fi
  cmp "$fixture/before" "$settings" || fail 'invalid settings overwritten'
  grep -q 'existing settings were preserved' "$fixture/output"
done

# A failed atomic replacement also preserves the original and cleans up.
printf '%s\n' '{"user":"keep"}' >"$settings"
cp "$settings" "$fixture/before"
mkdir "$fixture/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$fixture/bin/mv"
chmod +x "$fixture/bin/mv"
if PATH="$fixture/bin:$PATH" merge >"$fixture/output" 2>&1; then fail 'failed write returned success'; fi
cmp "$fixture/before" "$settings" || fail 'failed write changed settings'
grep -q 'cannot replace settings file' "$fixture/output"

# A failed temporary-file write cannot consume a stale predictable .tmp file.
printf '%s\n' 'untouched' >"$settings.tmp"
printf '#!/usr/bin/env bash\nexit 1\n' >"$fixture/bin/mktemp"
chmod +x "$fixture/bin/mktemp"
if PATH="$fixture/bin:$PATH" merge >"$fixture/output" 2>&1; then fail 'failed temporary file returned success'; fi
cmp "$fixture/before" "$settings" || fail 'temporary-file failure changed settings'
[ "$(cat "$settings.tmp")" = untouched ] || fail 'predictable temporary file modified'
shopt -s nullglob
leftovers=("$settings".tmp.*)
[ "${#leftovers[@]}" -eq 0 ] || fail 'temporary files leaked'

echo 'Claude settings merge tests passed'
