#!/usr/bin/env bash
# Contract tests for t3-thread-overview-ack (ADR-0091).
set -euo pipefail

dir=modules/home-manager/programs/ai
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# The Nix wrapper prepends these settings; do the same here.
{
  echo 'set -euo pipefail'
  echo "ack_file_default=$tmp/state/t3-thread-overview/acknowledged.json"
  cat "$dir/t3-thread-id.sh" "$dir/t3-thread-overview-ack.sh"
} >"$tmp/ack"
file=$tmp/state/t3-thread-overview/acknowledged.json

# Recording creates the file; a second record of a thread keeps its latest time.
bash "$tmp/ack" mcp:a1@2026-10-17T10:00:00.000Z b2@2026-10-18T02:30:12Z 2>/dev/null
bash "$tmp/ack" mcp:a1@2026-10-18T09:00:00.000Z 2>/dev/null
[[ $(jq -cS . "$file") == '{"b2":"2026-10-18T02:30:12Z","mcp:a1":"2026-10-18T09:00:00.000Z"}' ]] ||
  fail "unexpected file: $(cat "$file")"
[[ $(bash "$tmp/ack" --list | jq -c 'keys') == '["b2","mcp:a1"]' ]] || fail "--list"
bash "$tmp/ack" --forget b2
[[ $(jq -c . "$file") == '{"mcp:a1":"2026-10-18T09:00:00.000Z"}' ]] || fail "--forget: $(cat "$file")"
# T3_OVERVIEW_ACK_FILE overrides the default.
T3_OVERVIEW_ACK_FILE=$tmp/other.json bash "$tmp/ack" c3@2026-10-18T00:00:00Z 2>/dev/null
[[ $(jq -c . "$tmp/other.json") == '{"c3":"2026-10-18T00:00:00Z"}' ]] || fail "override"

# Anything that is not ID@SETTLED_AT is refused before the file changes.
before=$(<"$file")
for arg in no-time "a b@2026-10-18T00:00:00Z" "x'y@2026-10-18T00:00:00Z" "a@yesterday" "a@2026-10-18T00:00:00Z;rm"; do
  status=0
  bash "$tmp/ack" ok@2026-10-18T00:00:00Z "$arg" 2>/dev/null || status=$?
  [[ "$status" == 64 ]] || fail "$arg exited $status"
done
status=0
bash "$tmp/ack" --forget "x'y" 2>/dev/null || status=$?
[[ "$status" == 64 ]] || fail "bad --forget ID exited $status"
[[ $(<"$file") == "$before" ]] || fail "a refused call changed the file"
for args in "" "--list extra" "--forget"; do
  status=0
  # shellcheck disable=SC2086 # split on purpose
  bash "$tmp/ack" $args 2>/dev/null || status=$?
  [[ "$status" == 64 ]] || fail "usage '$args' exited $status"
done

# IDs that look like jq options are data, not options.
bash "$tmp/ack" -x@2026-10-18T00:00:00Z 2>/dev/null
bash "$tmp/ack" --forget --version
[[ $(jq -c . "$file") == '{"mcp:a1":"2026-10-18T09:00:00.000Z","-x":"2026-10-18T00:00:00Z"}' ]] ||
  fail "option-like IDs: $(cat "$file")"
bash "$tmp/ack" --forget -x

# Concurrent calls keep every entry.
for n in 1 2 3 4 5 6 7 8; do
  bash "$tmp/ack" "p$n@2026-10-18T00:00:0${n}Z" 2>/dev/null &
done
wait
[[ $(jq '[keys[] | select(startswith("p"))] | length' "$file") == 8 ]] || fail "concurrent calls lost entries"

# A broken file is reported, not overwritten.
for broken in '["not", "an object"]' '{} {}'; do
  printf '%s\n' "$broken" >"$file"
  status=0
  bash "$tmp/ack" d4@2026-10-18T00:00:00Z 2>/dev/null || status=$?
  [[ "$status" == 65 && $(<"$file") == "$broken" ]] || fail "broken file $broken exited $status"
done

echo "t3-thread-overview-ack: ok"
