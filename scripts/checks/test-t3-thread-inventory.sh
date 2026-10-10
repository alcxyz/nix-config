#!/usr/bin/env bash
# Contract tests for the T3 thread inventory (ADR-0091).
set -euo pipefail

dir=modules/home-manager/programs/ai
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# The Nix wrapper prepends these settings; do the same here.
{
  echo 'set -euo pipefail'
  echo "inventory_sql=$PWD/$dir/t3-thread-inventory.sql"
  echo "default_dbs=$tmp/missing.sqlite:$tmp/state.sqlite"
  cat "$dir/t3-thread-inventory.sh"
} >"$tmp/inventory"

recent=$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%S.000Z)
old=$(date -u -d '-10 days' +%Y-%m-%dT%H:%M:%S.000Z)
sqlite3 "$tmp/state.sqlite" <<SQL
CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL,
  title TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT, deleted_at TEXT,
  payload_json TEXT NOT NULL);
CREATE TABLE orchestration_v2_projection_runs (run_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL, status TEXT NOT NULL);
CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT NOT NULL);
INSERT INTO projection_projects VALUES ('p1', 'alpha');
INSERT INTO orchestration_v2_projection_threads VALUES
  ('open', 'p1', 'Open work', '$old', '$recent', NULL, NULL,
   '{"settledOverride":null,"settledAt":null,"lineage":{},"snoozedUntil":"$old","pullRequests":[{"url":"https://forge.invalid/pulls/7","snapshot":{"state":"open"}}]}'),
  ('caller', 'p1', 'This overview', '$old', '$recent', NULL, NULL, '{"settledOverride":null,"settledAt":null,"lineage":{}}'),
  ('child', 'p1', 'Subagent', '$old', '$recent', NULL, NULL,
   '{"settledOverride":null,"settledAt":null,"lineage":{"relationshipToParent":"subagent"}}'),
  ('recent', 'p2', 'Settled yesterday', '$old', '$recent', NULL, NULL,
   '{"settledOverride":"settled","settledAt":"$recent","lineage":{}}'),
  ('stale', 'p1', 'Settled long ago', '$old', '$old', NULL, NULL, '{"settledOverride":"settled","settledAt":"$old","lineage":{}}'),
  ('archived', 'p1', 'Archived', '$old', '$recent', '$recent', NULL, '{"settledOverride":null,"settledAt":null,"lineage":{}}');
INSERT INTO orchestration_v2_projection_runs VALUES ('r1', 'open', 1, 'completed'), ('r2', 'open', 2, 'running');
SQL

out=$(bash "$tmp/inventory" --thread caller)
test "$(jq -r '.database' <<<"$out")" = "$tmp/state.sqlite"
test "$(jq -c '[.threads[].threadId]' <<<"$out")" = '["open","recent"]'
test "$(jq -r '.threads[0] | [.project, .bucket, .status, (.snoozedUntil // "none"), .prs[0].state] | join(" ")' <<<"$out")" = 'alpha unsettled running none open'
test "$(jq -r '.threads[1] | [.project, .bucket, .status] | join(" ")' <<<"$out")" = 'p2 recently-settled idle'
test "$(bash "$tmp/inventory" --thread caller --days 30 | jq '.threads | length')" = 3
test "$(bash "$tmp/inventory" | jq '.threads | length')" = 3

if bash "$tmp/inventory" --thread elsewhere 2>"$tmp/err"; then exit 1; else test $? = 2; fi
grep -q 'no readable T3 state database holding thread elsewhere' "$tmp/err"
if bash "$tmp/inventory" --thread "x'y" 2>/dev/null; then exit 1; else test $? = 64; fi
if bash "$tmp/inventory" --days soon 2>/dev/null; then exit 1; else test $? = 64; fi

# IDs that look like numbers still match as text.
sqlite3 "$tmp/state.sqlite" "INSERT INTO orchestration_v2_projection_threads VALUES ('1e5', 'p1', 'Numeric-looking', '$old', '$recent', NULL, NULL, '{\"settledOverride\":null,\"settledAt\":null,\"lineage\":{}}');"
test "$(bash "$tmp/inventory" --thread 1e5 | jq -c '[.threads[].threadId] | sort')" = '["caller","open","recent"]'

# A payload without settlement fields means T3's schema moved: fail, don't guess.
sqlite3 "$tmp/state.sqlite" "INSERT INTO orchestration_v2_projection_threads VALUES ('new', 'p1', 'New shape', '$old', '$recent', NULL, NULL, '{\"lineage\":{}}');"
if bash "$tmp/inventory" --thread caller 2>"$tmp/err"; then exit 1; else test $? = 3; fi
grep -q "schema has changed" "$tmp/err"
sqlite3 "$tmp/empty.sqlite" 'CREATE TABLE unrelated (a);'
if bash "$tmp/inventory" --db "$tmp/empty.sqlite" 2>/dev/null; then exit 1; else test $? = 3; fi
if bash "$tmp/inventory" --db "$tmp/empty.sqlite" --thread caller 2>"$tmp/err"; then exit 1; else test $? = 3; fi
grep -q 'schema may have changed' "$tmp/err"

echo "t3-thread-inventory tests passed"
