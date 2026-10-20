#!/usr/bin/env bash
# Contract tests for t3-thread-messages (ADR-0091, #757).
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
  echo "messages_sql=$PWD/$dir/t3-thread-messages.sql"
  echo "default_dbs=$tmp/missing.sqlite:$tmp/state.sqlite"
  cat "$dir/t3-thread-id.sh" "$dir/t3-state-db.sh" "$dir/t3-thread-messages.sh"
} >"$tmp/messages"

sqlite3 "$tmp/state.sqlite" <<'SQL'
CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, payload_json TEXT NOT NULL);
CREATE TABLE orchestration_v2_projection_provider_threads (provider_thread_id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL, payload_json TEXT NOT NULL);
CREATE TABLE orchestration_v2_projection_messages (message_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL,
  role TEXT NOT NULL, streaming INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  payload_json TEXT NOT NULL);
INSERT INTO orchestration_v2_projection_threads VALUES
  ('t1', '{"settledOverride":null,"settledAt":null,"lineage":{},"activeProviderThreadId":null}'),
  ('quiet', '{"settledOverride":null,"settledAt":null,"lineage":{},"activeProviderThreadId":null}');
INSERT INTO orchestration_v2_projection_messages VALUES
  ('m1', 't1', 'user', 0, '2026-10-20T10:00:01.000Z', '2026-10-20T10:00:01.000Z', '{"text":"Build the dashboard"}'),
  ('m2', 't1', 'assistant', 0, '2026-10-20T10:00:02.000Z', '2026-10-20T10:00:02.000Z', '{"text":"Reading the code"}'),
  ('m3', 't1', 'user', 0, '2026-10-20T10:00:03.000Z', '2026-10-20T10:00:03.000Z', '{"text":"Task finished","notification":{"kind":"task"}}'),
  ('m4', 't1', 'assistant', 0, '2026-10-20T10:00:04.000Z', '2026-10-20T10:00:04.000Z', '{"text":"Child result in","delegatedCompletion":null}'),
  ('m5', 't1', 'user', 0, '2026-10-20T10:00:05.000Z', '2026-10-20T10:00:05.000Z', '{"text":"Ship it","delegatedCompletion":{"taskId":"x"}}'),
  ('m6', 't1', 'assistant', 1, '2026-10-20T10:00:06.000Z', '2026-10-20T10:00:06.000Z', '{"text":"Still typing"}'),
  ('m7', 't1', 'system', 0, '2026-10-20T10:00:07.000Z', '2026-10-20T10:00:07.000Z', '{"text":"internal"}'),
  ('m8', 't1', 'assistant', 0, '2026-10-20T10:00:08.000Z', '2026-10-20T10:00:08.000Z', '{"text":"Ærlig talt, done: ✓✓✓"}'),
  ('o1', 'other', 'user', 0, '2026-10-20T10:00:00.000Z', '2026-10-20T10:00:00.000Z', '{"text":"another thread"}');
SQL

out=$(bash "$tmp/messages" --head 1 --tail 2 --max-chars 12 t1)
# Finished user and assistant messages only, numbered in thread order; the
# first --head and last --tail, each cut with a trailing ellipsis; latest is
# the newest finished message.
[[ $(jq -c '[.threadId, .messageCount, .latest]' <<<"$out") == '["t1",6,{"id":"m8","at":"2026-10-20T10:00:08.000Z"}]' ]] ||
  fail "unexpected header: $out"
[[ $(jq -c '[.messages[] | [.position, .role, .kind, .text]]' <<<"$out") == '[[1,"user","message","Build the da…"],[5,"user","notification","Ship it"],[6,"assistant","message","Ærlig talt, …"]]' ]] ||
  fail "unexpected messages: $out"
[[ $(bash "$tmp/messages" --head 3 --tail 2 t1 | jq -c '[.messages[] | [.position, .kind]]') == '[[1,"message"],[2,"message"],[3,"notification"],[5,"notification"],[6,"message"]]' ]] ||
  fail "head and tail did not merge in order"
# A message created earlier that finishes later leaves latest alone but
# changes the revision, so a summary keyed on it goes stale.
before=$(jq -r .revision <<<"$out")
sqlite3 "$tmp/state.sqlite" "UPDATE orchestration_v2_projection_messages SET streaming = 0, updated_at = '2026-10-20T10:00:09.000Z' WHERE message_id = 'm6';"
after=$(bash "$tmp/messages" t1)
[[ $(jq -c '[.latest.id, .messageCount, .lastActivityAt]' <<<"$after") == '["m8",7,"2026-10-20T10:00:09.000Z"]' ]] ||
  fail "finishing an older message: $after"
[[ $(jq -r .revision <<<"$after") != "$before" ]] || fail "revision did not change"
sqlite3 "$tmp/state.sqlite" "UPDATE orchestration_v2_projection_messages SET streaming = 1 WHERE message_id = 'm6';"
# Overlapping head and tail list each message once.
[[ $(bash "$tmp/messages" --head 5 --tail 5 t1 | jq '.messages | length') == 6 ]] || fail "overlap repeated messages"
# A thread without messages has none, and no latest.
[[ $(bash "$tmp/messages" quiet | jq -c '[.messageCount, .latest, .messages, .revision, .lastActivityAt]') == '[0,null,[],"0:",null]' ]] ||
  fail "empty thread"

status=0
bash "$tmp/messages" other 2>"$tmp/err" || status=$?
[[ "$status" == 2 ]] || fail "unknown thread exited $status"
grep -q 'holding thread other' "$tmp/err" || fail "unknown thread message"
for args in "" "--head x t1" "--tail" "t1 t2" "x'y" "--bogus t1"; do
  status=0
  # shellcheck disable=SC2086 # split on purpose
  bash "$tmp/messages" $args 2>/dev/null || status=$?
  [[ "$status" == 64 ]] || fail "args '$args' exited $status"
done

# A finished message without its text means T3's schema moved: fail loudly,
# for that thread only.
sqlite3 "$tmp/state.sqlite" "INSERT INTO orchestration_v2_projection_messages VALUES ('m9', 't1', 'user', 0, '2026-10-20T10:00:09.000Z', '2026-10-20T10:00:09.000Z', '{\"body\":\"moved\"}');"
bash "$tmp/messages" quiet >/dev/null || fail "another thread's message failed this one"
status=0
bash "$tmp/messages" t1 2>"$tmp/err" || status=$?
[[ "$status" == 3 ]] || fail "schema drift exited $status"
grep -q "messages lack their text" "$tmp/err" || fail "schema drift message"

echo "t3-thread-messages tests passed"
