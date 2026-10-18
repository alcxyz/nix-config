#!/usr/bin/env bash
# Contract tests for the T3 thread inventory (ADR-0091).
set -euo pipefail

dir=modules/home-manager/programs/ai
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# The Nix wrapper prepends these settings; do the same here.
{
  echo 'set -euo pipefail'
  echo "common_sql=$PWD/$dir/t3-thread-common.sql"
  echo "inventory_sql=$PWD/$dir/t3-thread-inventory.sql"
  echo "default_dbs=$tmp/missing.sqlite:$tmp/state.sqlite"
  cat "$dir/t3-thread-id.sh" "$dir/t3-state-db.sh" "$dir/t3-thread-inventory.sh"
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
CREATE TABLE orchestration_v2_projection_provider_threads (provider_thread_id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL, status TEXT NOT NULL, payload_json TEXT NOT NULL);
CREATE TABLE orchestration_v2_projection_turn_items (turn_item_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL,
  run_id TEXT, type TEXT NOT NULL, status TEXT NOT NULL, payload_json TEXT NOT NULL);
INSERT INTO projection_projects VALUES ('p1', 'alpha');
INSERT INTO orchestration_v2_projection_threads VALUES
  ('open', 'p1', 'Open work', '$old', '$recent', NULL, NULL,
   '{"settledOverride":null,"settledAt":null,"lineage":{},"activeProviderThreadId":null,"snoozedUntil":"$old","pullRequests":[{"url":"https://forge.invalid/pulls/7","snapshot":{"state":"open"}}]}'),
  ('waits', 'p1', 'Waiting work', '$old', '$old', NULL, NULL,
   '{"settledOverride":null,"settledAt":null,"lineage":{},"activeProviderThreadId":"pt-live"}'),
  ('caller', 'p1', 'This overview', '$old', '$recent', NULL, NULL, '{"settledOverride":null,"settledAt":null,"lineage":{},"activeProviderThreadId":null}'),
  ('child', 'p1', 'Subagent', '$old', '$recent', NULL, NULL,
   '{"settledOverride":null,"settledAt":null,"lineage":{"relationshipToParent":"subagent"},"activeProviderThreadId":null}'),
  ('recent', 'p2', 'Settled yesterday', '$old', '$recent', NULL, NULL,
   '{"settledOverride":"settled","settledAt":"$recent","lineage":{},"activeProviderThreadId":null,"pullRequests":[{"url":"https://forge.invalid/pulls/9","number":9,"source":"agent","watch":{}},{"url":"https://forge.invalid/pulls/8","number":8,"watch":{},"source":"stack-dismissed"},{"url":"https://forge.invalid/pulls/6","number":6,"watch":null}]}'),
  ('stale', 'p1', 'Settled long ago', '$old', '$old', NULL, NULL, '{"settledOverride":"settled","settledAt":"$old","lineage":{},"activeProviderThreadId":null}'),
  ('archived', 'p1', 'Archived', '$old', '$recent', '$recent', NULL, '{"settledOverride":null,"settledAt":null,"lineage":{},"activeProviderThreadId":null}');
INSERT INTO orchestration_v2_projection_runs VALUES ('r1', 'open', 1, 'completed'), ('r2', 'open', 2, 'running'),
  ('w0', 'waits', 1, 'rolled_back'), ('w1', 'waits', 2, 'completed');
INSERT INTO orchestration_v2_projection_provider_threads VALUES
  ('pt-open', 'open', 'idle', '{"pendingBackgroundTasks":[{"taskId":"o","kind":"monitor"}]}'),
  ('pt-live', 'waits', 'idle', '{"pendingBackgroundTasks":[{"taskId":"a","kind":"monitor","description":"pr-review run 7"},{"taskId":"b","kind":"command"},{"taskId":"c"}]}'),
  ('pt-old', 'waits', 'idle', '{"pendingBackgroundTasks":[{"taskId":"z","kind":"command","description":"replaced session"}]}');
INSERT INTO orchestration_v2_projection_turn_items VALUES
  ('i1', 'waits', 'w1', 'subagent', 'running', '{"title":"","prompt":"Check the docs","nativeItemRef":{"nativeId":"s1"}}'),
  ('i2', 'waits', 'w1', 'command_execution', 'running', '{"title":"duplicate of a","nativeItemRef":{"nativeId":"a"}}'),
  ('i3', 'waits', 'w1', 'dynamic_tool', 'running', '{"toolName":"watcher","input":{"persistent":true}}'),
  ('i4', 'waits', 'w0', 'command_execution', 'running', '{"title":"abandoned"}'),
  ('i5', 'waits', 'w1', 'command_execution', 'completed', '{"title":"finished"}');
SQL

out=$(bash "$tmp/inventory" --thread caller)
test "$(jq -r '.database' <<<"$out")" = "$tmp/state.sqlite"
test "$(jq -c '[.threads[].threadId]' <<<"$out")" = '["open","waits","recent"]'
test "$(jq -r '.threads[0] | [.project, .bucket, .status, (.snoozedUntil // "none"), .prs[0].state] | join(" ")' <<<"$out")" = 'alpha unsettled running none open'
test "$(jq -r '.threads[2] | [.project, .bucket, .status] | join(" ")' <<<"$out")" = 'p2 recently-settled idle'
# A PR link dismissed from a stack is left out, as in t3-thread-status.
test "$(jq -c '[.threads[2].prs[].url]' <<<"$out")" = '["https://forge.invalid/pulls/6","https://forge.invalid/pulls/9"]'
# Background work as T3 derives it (#627): none while a run is active; the
# active provider thread's roster, active turn items not from rolled-back runs
# or persistent tools, deduplicated by task ID; a task without a kind counts
# as background_task; only watches before a first run, and a null watch is none.
test "$(jq -c '.threads[0].waitingOn' <<<"$out")" = '[]'
test "$(jq -c '.threads[1].waitingOn | sort_by(.kind)' <<<"$out")" = '[{"kind":"background_task","description":null},{"kind":"command","description":null},{"kind":"monitor","description":"pr-review run 7"},{"kind":"subagent","description":"Check the docs"}]'
test "$(jq -c '.threads[2].waitingOn' <<<"$out")" = '[{"kind":"monitor","description":"Watching pull request #9"}]'
test "$(bash "$tmp/inventory" --thread caller --days 30 | jq '.threads | length')" = 4
test "$(bash "$tmp/inventory" | jq '.threads | length')" = 4

# A settled thread the user acknowledged is marked while its settle time
# matches; a broken acknowledgement file only warns.
echo "{\"recent\": \"$recent\", \"open\": \"$recent\"}" >"$tmp/acks.json"
test "$(T3_OVERVIEW_ACK_FILE=$tmp/acks.json bash "$tmp/inventory" --thread caller | jq -c '[.threads[] | select(.acknowledged) | .threadId]')" = '["recent"]'
echo "{\"recent\": \"$old\"}" >"$tmp/acks.json"
test "$(T3_OVERVIEW_ACK_FILE=$tmp/acks.json bash "$tmp/inventory" --thread caller | jq '[.threads[] | select(.acknowledged)] | length')" = 0
for broken in 'not json' '{} {}'; do
  echo "$broken" >"$tmp/acks.json"
  test "$(T3_OVERVIEW_ACK_FILE=$tmp/acks.json bash "$tmp/inventory" --thread caller 2>"$tmp/err" | jq '.threads | length')" = 3
  grep -q 'not an acknowledgement file' "$tmp/err"
done

if bash "$tmp/inventory" --thread elsewhere 2>"$tmp/err"; then exit 1; else test $? = 2; fi
grep -q 'no readable T3 state database holding thread elsewhere' "$tmp/err"
if bash "$tmp/inventory" --thread "x'y" 2>/dev/null; then exit 1; else test $? = 64; fi
if bash "$tmp/inventory" --days soon 2>/dev/null; then exit 1; else test $? = 64; fi

# IDs that look like numbers still match as text.
sqlite3 "$tmp/state.sqlite" "INSERT INTO orchestration_v2_projection_threads VALUES ('1e5', 'p1', 'Numeric-looking', '$old', '$recent', NULL, NULL, '{\"settledOverride\":null,\"settledAt\":null,\"lineage\":{},\"activeProviderThreadId\":null}');"
test "$(bash "$tmp/inventory" --thread 1e5 | jq -c '[.threads[].threadId] | sort')" = '["caller","open","recent","waits"]'

# A payload without settlement fields means T3's schema moved: fail, don't guess.
sqlite3 "$tmp/state.sqlite" "INSERT INTO orchestration_v2_projection_threads VALUES ('new', 'p1', 'New shape', '$old', '$recent', NULL, NULL, '{\"lineage\":{}}');"
if bash "$tmp/inventory" --thread caller 2>"$tmp/err"; then exit 1; else test $? = 3; fi
grep -q "schema has changed" "$tmp/err"
sqlite3 "$tmp/state.sqlite" "DELETE FROM orchestration_v2_projection_threads WHERE thread_id = 'new';"
bash "$tmp/inventory" --thread caller >/dev/null
# So is a provider thread without a background task list, or with a broken payload.
for payload in '{}' 'not json'; do
  sqlite3 "$tmp/state.sqlite" "INSERT OR REPLACE INTO orchestration_v2_projection_provider_threads VALUES ('pt-new', 'open', 'idle', '$payload');"
  if bash "$tmp/inventory" --thread caller 2>"$tmp/err"; then exit 1; else test $? = 3; fi
  grep -q "lack a background task list in .*; T3's schema has changed" "$tmp/err"
done
sqlite3 "$tmp/empty.sqlite" 'CREATE TABLE unrelated (a);'
if bash "$tmp/inventory" --db "$tmp/empty.sqlite" 2>/dev/null; then exit 1; else test $? = 3; fi
if bash "$tmp/inventory" --db "$tmp/empty.sqlite" --thread caller 2>"$tmp/err"; then exit 1; else test $? = 3; fi
grep -q 'schema may have changed' "$tmp/err"

echo "t3-thread-inventory tests passed"
