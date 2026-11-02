#!/usr/bin/env bash
set -euo pipefail

# ExecStartPost of every unit nixfleet tracks (ADR-0041): records which
# definition this invocation started from, world-readable, so a non-root
# `nixfleet status` can tell a unit that a switch did not restart.
# runner-state.sh compares the record with the deployed definition.

# shellcheck disable=SC1090
source "${STATE_HELPER_FILE:-$(dirname "${BASH_SOURCE[0]}")/runner-state.sh}"

unit=${1:-}
valid_unit "$unit" || {
  echo "invalid unit name" >&2
  exit 2
}
[[ ${INVOCATION_ID:-} =~ ^[0-9a-f]{32}$ ]] || {
  echo "no invocation ID" >&2
  exit 2
}
unit_state "$unit"
install -d -m 0755 -- "$record_dir"
tmp=$(mktemp "$record_dir/.$unit.XXXXXX")
printf 'invocation=%s\ndefinition=%s\n' "$INVOCATION_ID" "$definition" >"$tmp"
chmod 0644 -- "$tmp"
mv -f -- "$tmp" "$record_dir/$unit"
