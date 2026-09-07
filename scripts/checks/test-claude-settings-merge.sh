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
