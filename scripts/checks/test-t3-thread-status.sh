#!/usr/bin/env bash
# Contract tests for t3-thread-status (ADR-0091).
set -euo pipefail

dir=modules/home-manager/programs/ai
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# The Nix wrapper prepends these settings; do the same here.
{
  echo 'set -euo pipefail'
  echo "common_sql=$PWD/$dir/t3-thread-common.sql"
  echo "status_sql=$PWD/$dir/t3-thread-status.sql"
  echo "default_dbs=$tmp/missing.sqlite:$tmp/state.sqlite"
  cat "$dir/t3-state-db.sh" "$dir/t3-thread-status.sh"
} >"$tmp/status"
status() { bash "$tmp/status" "$@"; }

# Throwaway repositories: a remote with dev, and one worktree per case.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
git init -q --bare -b dev "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$tmp/seed" 2>/dev/null
git -C "$tmp/seed" commit -q --allow-empty -m base
# Two blocks with the same three lines around line 5 and line 13, for the
# moved case below.
block='[role]\n  a = 1\n  b = 2\n  c = 3\n  enabled = false\n  d = 4\n  e = 5\n  f = 6\n'
printf '%b%b' "$block" "$block" >"$tmp/seed/access.py"
git -C "$tmp/seed" add access.py
git -C "$tmp/seed" commit -q -m "add access.py"
git -C "$tmp/seed" push -q origin HEAD:dev
# change REPO FILE TEXT: commit one file's new content.
change() {
  echo "$3" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "$2: $3"
}
# branch NAME: a clone on feat/NAME with one pushed commit.
branch() {
  git clone -q "$tmp/remote.git" "$tmp/$1"
  git -C "$tmp/$1" switch -q -c "feat/$1"
  change "$tmp/$1" "$1.txt" "$1 work"
  git -C "$tmp/$1" push -q -u origin "feat/$1" 2>/dev/null
}
# squash NAME: merge feat/NAME into dev as one commit, as a forge squash does.
squash() {
  git -C "$tmp/seed" pull -q origin dev
  git -C "$tmp/seed" merge -q --squash "origin/feat/$1" >/dev/null 2>&1
  git -C "$tmp/seed" commit -q -m "feat: $1 (squashed)"
  git -C "$tmp/seed" push -q origin HEAD:dev
}
# merged: squash-merged with its branch still on the remote.
branch merged
# dirty: a changed file, an untracked file and an unpushed commit.
branch dirty
change "$tmp/dirty" dirty.txt "unpushed"
echo b >"$tmp/dirty/dirty.txt"
echo c >"$tmp/dirty/new"
# gone: pushed, then its remote branch was deleted without a merge.
branch gone
# squashed: squash-merged and deleted, and dev changed the file since, so only
# the squashed patch shows the work landed.
branch squashed
# followup: squash-merged and deleted, but with a commit the merge lacks.
branch followup
# quoted: the same, with the missing change in a file name git would quote.
branch quoted
# indent: the same, with the missing change only in a line's indentation,
# which a whitespace-blind patch comparison would miss.
branch indent
printf 'if ready:\n    start()\nfinish()\n' >"$tmp/indent/run.py"
git -C "$tmp/indent" add run.py
git -C "$tmp/indent" commit -q -m "add run.py"
git -C "$tmp/indent" push -q 2>/dev/null
# moved: the same, with the merged edit moved to an identical-looking place,
# which patch IDs alone cannot tell apart.
branch moved
sed -i '5s/false/true/' "$tmp/moved/access.py"
git -C "$tmp/moved" commit -q -am "enable admin"
git -C "$tmp/moved" push -q 2>/dev/null
git -C "$tmp/seed" fetch -q origin
for name in merged squashed followup quoted indent moved; do squash "$name"; done
change "$tmp/seed" squashed.txt "changed later on dev"
git -C "$tmp/seed" push -q origin HEAD:dev
change "$tmp/followup" followup-2.txt "after the merged head"
change "$tmp/quoted" "café.md" "after the merged head"
printf 'if ready:\n    start()\n    finish()\n' >"$tmp/indent/run.py"
git -C "$tmp/indent" commit -q -am "move finish() into the if"
sed -i '5s/true/false/; 13s/false/true/' "$tmp/moved/access.py"
git -C "$tmp/moved" commit -q -am "enable guest instead"
for name in gone squashed followup quoted indent moved; do git -C "$tmp/$name" push -q origin --delete "feat/$name" 2>/dev/null; done
for name in merged dirty gone squashed followup quoted indent moved; do git -C "$tmp/$name" fetch -q --prune; done
# switched: an unpushed commit on its branch, then the worktree switched to dev.
branch switched
change "$tmp/switched" switched.txt "unpushed"
git -C "$tmp/switched" switch -q dev
# movedon: its branch is pushed, but the worktree moved on to a new branch
# with an unpushed commit.
branch movedon
git -C "$tmp/movedon" switch -q -c feat/next
change "$tmp/movedon" next.txt "unpushed"
# offbranch: the thread's branch is not in the worktree at all.
git clone -q "$tmp/remote.git" "$tmp/offbranch"
# unreadable: the directory is there, but its git directory was pruned.
mkdir "$tmp/unreadable"
echo "gitdir: $tmp/pruned" >"$tmp/unreadable/.git"
echo edited >"$tmp/unreadable/file"
# unborn: no commits yet; broken: git cannot read its index.
git init -q -b dev "$tmp/unborn"
echo x >"$tmp/unborn/new"
git clone -q "$tmp/remote.git" "$tmp/broken"
echo garbage >"$tmp/broken/.git/index"

now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
recent=$(date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%S.000Z)
earlier=$(date -u -d '-20 minutes' +%Y-%m-%dT%H:%M:%S.000Z)
old=$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%S.000Z)
fields='"settledOverride":null,"settledAt":null,"lineage":{},"snoozedUntil":null'
sqlite3 "$tmp/state.sqlite" <<SQL
CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL,
  title TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT, deleted_at TEXT,
  payload_json TEXT NOT NULL);
CREATE TABLE orchestration_v2_projection_runs (run_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL, status TEXT NOT NULL, requested_at TEXT NOT NULL, completed_at TEXT);
CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT NOT NULL);
CREATE TABLE orchestration_v2_projection_provider_threads (provider_thread_id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL, status TEXT NOT NULL, payload_json TEXT NOT NULL);
CREATE TABLE orchestration_v2_projection_turn_items (turn_item_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL,
  run_id TEXT, type TEXT NOT NULL, status TEXT NOT NULL, payload_json TEXT NOT NULL);
CREATE TABLE orchestration_v2_projection_messages (message_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL,
  role TEXT NOT NULL, streaming INTEGER NOT NULL, created_at TEXT NOT NULL, payload_json TEXT NOT NULL);
INSERT INTO projection_projects VALUES ('p1', 'alpha');
INSERT INTO orchestration_v2_projection_threads VALUES
  ('merged', 'p1', 'Merged', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":null,"worktreePath":"$tmp/merged","branch":"feat/merged","pullRequests":[
     {"url":"https://forge.invalid/pulls/4","number":4,"source":"agent","snapshot":{"state":"merged","baseBranch":"dev"}},
     {"url":"https://forge.invalid/pulls/3","number":3,"source":"stack-dismissed","snapshot":{"state":"open","baseBranch":"dev"}}]}'),
  ('dirty', 'p1', 'Dirty', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":null,"worktreePath":"$tmp/dirty","branch":"feat/dirty","pullRequests":[
     {"url":"https://forge.invalid/pulls/5","number":5,"source":"agent","snapshot":{"state":"open","baseBranch":"dev"}}]}'),
  ('gone', 'p1', 'Gone', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":null,"worktreePath":"$tmp/gone","branch":"feat/gone"}'),
  ('squashed', 'p1', 'Squashed', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":null,"worktreePath":"$tmp/squashed","branch":"feat/squashed","pullRequests":[
     {"url":"https://forge.invalid/pulls/7","number":7,"source":"agent","snapshot":{"state":"merged","baseBranch":"dev"}}]}'),
  ('followup', 'p1', 'Follow-up', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":null,"worktreePath":"$tmp/followup","branch":"feat/followup","pullRequests":[
     {"url":"https://forge.invalid/pulls/8","number":8,"source":"agent","snapshot":{"state":"merged","baseBranch":"dev"}}]}'),
  ('quoted', 'p1', 'Quoted', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":null,"worktreePath":"$tmp/quoted","branch":"feat/quoted"}'),
  ('indent', 'p1', 'Indent', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":null,"worktreePath":"$tmp/indent","branch":"feat/indent"}'),
  ('moved', 'p1', 'Moved', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":null,"worktreePath":"$tmp/moved","branch":"feat/moved"}'),
  ('switched', 'p1', 'Switched', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":null,"worktreePath":"$tmp/switched","branch":"feat/switched"}'),
  ('movedon', 'p1', 'Moved on', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":null,"worktreePath":"$tmp/movedon","branch":"feat/movedon"}'),
  ('offbranch', 'p1', 'Off branch', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":null,"worktreePath":"$tmp/offbranch","branch":"feat/deleted","pullRequests":[
     {"url":"https://forge.invalid/pulls/9","number":9,"source":"agent","snapshot":{"state":"merged","baseBranch":"dev"}}]}'),
  ('unreadable', 'p1', 'Unreadable', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":null,"worktreePath":"$tmp/unreadable","branch":"feat/x"}'),
  ('unborn', 'p1', 'Unborn', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":null,"worktreePath":"$tmp/unborn","branch":"dev"}'),
  ('broken', 'p1', 'Broken', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":null,"worktreePath":"$tmp/broken","branch":"dev"}'),
  ('removed', 'p1', 'Removed worktree', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":null,"worktreePath":"$tmp/removed","branch":"feat/removed"}'),
  ('failed', 'p1', 'Failed', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":null,"worktreePath":null,"branch":null}'),
  ('quiet', 'p1', 'Quiet', '$old', '$old', NULL, NULL,
   '{$fields,"activeProviderThreadId":null,"worktreePath":null,"branch":null}'),
  ('waits', 'p1', 'Waits', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":"pt-waits","worktreePath":null,"branch":null}'),
  ('self', 'p1', 'Self', '$old', '$recent', NULL, NULL,
   '{$fields,"activeProviderThreadId":"pt-self","worktreePath":null,"branch":null,"pullRequests":[
     {"url":"https://forge.invalid/pulls/6","number":6,"source":"agent","snapshot":{"state":"open","baseBranch":"dev"},"watch":{}}]}');
INSERT INTO orchestration_v2_projection_runs VALUES
  ('d1', 'merged', 1, 'completed', '$earlier', '$recent'),
  ('x1', 'dirty', 1, 'completed', '$earlier', '$recent'),
  ('g1', 'gone', 1, 'completed', '$earlier', '$recent'),
  ('sq1', 'squashed', 1, 'completed', '$earlier', '$recent'), ('fu1', 'followup', 1, 'completed', '$earlier', '$recent'),
  ('qu1', 'quoted', 1, 'completed', '$earlier', '$recent'), ('in1', 'indent', 1, 'completed', '$earlier', '$recent'),
  ('mv1', 'moved', 1, 'completed', '$earlier', '$recent'),
  ('sw1', 'switched', 1, 'completed', '$earlier', '$recent'), ('mo1', 'movedon', 1, 'completed', '$earlier', '$recent'), ('ob1', 'offbranch', 1, 'completed', '$earlier', '$recent'),
  ('ur1', 'unreadable', 1, 'completed', '$earlier', '$recent'),
  ('u1', 'unborn', 1, 'completed', '$earlier', '$recent'), ('b1', 'broken', 1, 'completed', '$earlier', '$recent'),
  ('f1', 'failed', 1, 'completed', '$old', '$old'), ('f2', 'failed', 2, 'failed', '$earlier', '$recent'),
  ('q1', 'quiet', 1, 'completed', '$old', '$old'),
  ('w1', 'waits', 1, 'completed', '$earlier', '$recent'),
  ('s1', 'self', 1, 'running', '$recent', NULL);
INSERT INTO orchestration_v2_projection_provider_threads VALUES
  ('pt-waits', 'waits', 'idle', '{"pendingBackgroundTasks":[{"taskId":"m","kind":"monitor","description":"pr-review run 5"}]}'),
  ('pt-self', 'self', 'running', '{"pendingBackgroundTasks":[{"taskId":"n","kind":"monitor","description":"wait for marker"}]}');
INSERT INTO orchestration_v2_projection_turn_items VALUES
  ('i1', 'self', 's1', 'command_execution', 'running', '{"title":"t3-thread-status --self self"}');
INSERT INTO orchestration_v2_projection_messages VALUES
  ('m1', 'merged', 'user', 0, '$earlier', '{"text":"Ship it."}'),
  ('m2', 'merged', 'assistant', 0, '$earlier', '{"text":"Working."}'),
  ('m3', 'merged', 'assistant', 0, '$recent', '{"text":"Merged.\n\n**Left for you:** deploy.\n**Settle:** ready.\n"}'),
  ('m4', 'dirty', 'assistant', 0, '$recent', '{"text":"**Settle:** ready."}'),
  ('m5', 'dirty', 'user', 0, '$now', '{"text":"One more thing."}'),
  ('m6', 'dirty', 'assistant', 1, '$now', '{"text":"**Settle:** still streaming"}'),
  ('m7', 'gone', 'assistant', 0, '$recent', '{"text":"Settle: not yet: deploy pending, user"}'),
  ('m8', 'quiet', 'assistant', 0, '$old', '{"text":"Which option do you prefer?"}'),
  ('m10', 'failed', 'assistant', 0, '$recent', '{"text":"**Settle:** maybe later"}'),
  ('m11', 'squashed', 'assistant', 0, '$recent', '{"text":"Use this form:\n\n\u0060\u0060\u0060\n**Settle:** ready.\n\u0060\u0060\u0060\nThe fix still needs work."}'),
  ('m12', 'self', 'assistant', 0, '$earlier', '{"text":"**Settle:** ready."}'),
  ('m13', 'switched', 'assistant', 0, '$recent', '{"text":"**Settle:** not yet: $(printf 'x%.0s' {1..400}), agent."}');
SQL
before=$(sha256sum "$tmp/state.sqlite" "$tmp"/{merged,dirty,gone,squashed,followup,quoted,indent,moved,switched,movedon,offbranch}/.git/index)

out=$(status merged dirty gone squashed followup quoted indent moved switched movedon offbranch unreadable unborn broken removed failed quiet waits)
test "$(jq -r '.database' <<<"$out")" = "$tmp/state.sqlite"
test "$(jq -c '[.threads[].threadId]' <<<"$out")" = '["merged","dirty","gone","squashed","followup","quoted","indent","moved","switched","movedon","offbranch","unreadable","unborn","broken","removed","failed","quiet","waits"]'
row() { jq -c --arg id "$1" ".threads[] | select(.threadId == \$id) | $2" <<<"$out"; }
check() { row "$1" "[.checks[] | select(.id == \"$2\") | .pass, .detail]"; }

# Merged by squash and pushed: ready, with the Settle: line from the newest
# finished message and the stack-dismissed PR left out.
test "$(row merged '[.project, .state, .run.status, .verdict]')" = '["alpha","unsettled","completed","ready"]'
test "$(row merged '.settle | [.verdict, .line, .stale]')" = '["ready","ready.",false]'
test "$(check merged pushed)" = '[true,"all pushed"]'
test "$(check merged landed)" = '[true,"changes are in origin/dev"]'
test "$(row merged '[.prs[].number]')" = '[4]'
test "$(row merged '.worktree | [.exists, .head, .changed, .untracked, (.branches[] | .name, .unpushed, .upstreamGone, .base, .aheadOfBase, .inBase)]')" = '[true,"feat/merged",0,0,"feat/merged",0,false,"origin/dev",1,true]'
test "$(row merged '[.checks[].pass] | all')" = true

# Dirty and unpushed, with a Settle: line the user answered since: stalled.
test "$(row dirty '.settle | [.verdict, .stale]')" = '["ready",true]'
test "$(row dirty '.worktree | [.changed, .untracked, (.branches[] | .unpushed, .upstream, .aheadOfBase)]')" = '[1,1,1,"origin/feat/dirty",2]'
test "$(check dirty clean)" = '[false,"1 changed, 1 untracked"]'
test "$(check dirty pushed)" = '[false,"feat/dirty: 1 commit not pushed to origin/feat/dirty"]'
test "$(check dirty landed)" = '[false,"feat/dirty: 2 commits not in origin/dev"]'
test "$(check dirty prs)" = '[false,"#5"]'
test "$(check dirty settle)" = '[null,"Settle: line predates the latest user message"]'
test "$(row dirty '[.verdict, .stallReasons]')" = '["stalled",["uncommitted changes","unpushed commits"]]'

# Upstream deleted: its commit counts as on no remote branch. The thread says
# what remains, so it is not yet done rather than stalled.
test "$(row gone '.worktree.branches | map([.upstreamGone, .unpushed, .upstream])')" = '[[true,1,"origin/feat/gone"]]'
test "$(check gone pushed)" = '[false,"feat/gone: 1 commit on no remote branch (upstream gone)"]'
test "$(row gone '[.settle.verdict, .settle.line, .settle.owner, .verdict, .stallReasons]')" = '["not-yet","not yet: deploy pending, user","user","not-yet",[]]'

# Squash-merged, branch deleted, file changed on dev since: the squashed patch
# shows the commit left behind landed.
# A Settle: line inside an example, not on the last line, does not count.
test "$(row squashed '.worktree.branches | map([.unpushed, .aheadOfBase, .inBase])')" = '[[1,1,true]]'
test "$(check squashed pushed)" = '[true,"feat/squashed: 1 commit on no remote branch, but their changes are in origin/dev"]'
test "$(check squashed landed)" = '[true,"changes are in origin/dev"]'
test "$(row squashed '[.settle, .verdict, .stallReasons]')" = '[null,"not-yet",[]]'
# A commit the squash merge lacks is neither pushed nor merged, however old.
test "$(row followup '.worktree.branches | map([.unpushed, .aheadOfBase, .inBase])')" = '[[2,2,false]]'
test "$(check followup pushed)" = '[false,"feat/followup: 2 commits on no remote branch (upstream gone)"]'
test "$(check followup landed)" = '[false,"feat/followup: 2 commits not in origin/dev"]'
test "$(row followup '[.verdict, .stallReasons]')" = '["stalled",["unpushed commits"]]'
# So is one in a file name git quotes, one that only changes indentation, or
# one that moves the merged edit somewhere that looks the same.
test "$(row quoted '.worktree.branches | map([.unpushed, .inBase])')" = '[[2,false]]'
test "$(row indent '.worktree.branches | map([.unpushed, .inBase])')" = '[[3,false]]'
test "$(row moved '.worktree.branches | map([.unpushed, .inBase])')" = '[[3,false]]'
test "$(check indent pushed)" = '[false,"feat/indent: 3 commits on no remote branch (upstream gone)"]'

# Facts cover the thread's branch as well as what the worktree has checked out.
test "$(row switched '.worktree | [.branch, .head, (.branches | map([.name, .unpushed, .missing]))]')" = '["feat/switched","dev",[["feat/switched",1,false],["dev",0,false]]]'
test "$(check switched pushed)" = '[false,"feat/switched: 1 commit not pushed to origin/feat/switched"]'
# A Settle: line's owner is read before the line is shortened for display.
test "$(row switched '.settle | [.verdict, .owner, (.line | length)]')" = '["not-yet","agent",300]'
test "$(check movedon pushed)" = '[false,"feat/next: 1 commit on no remote branch"]'
# A branch gone from the worktree leaves its commits unknown; its merged pull
# request still shows the work landed.
test "$(row offbranch '.worktree | [.head, (.branches | map([.name, .missing]))]')" = '["dev",[["feat/deleted",true],["dev",false]]]'
test "$(check offbranch pushed)" = '[null,"feat/deleted: not in the worktree"]'
test "$(check offbranch landed)" = '[true,"pull request merged"]'
# A directory git cannot open is an error, not a removed worktree.
test "$(row unreadable '.worktree | [.exists, .error]')" = '[true,"git could not read the worktree"]'

# No commits yet, or a worktree git cannot read: reported, not fatal.
test "$(row unborn '.worktree | [.exists, .changed, .untracked, (.branches[] | .unpushed, .aheadOfBase)]')" = '[true,0,1,0,null]'
test "$(row broken '.worktree.error')" = '"git could not read the worktree"'
test "$(check broken clean)" = '[null,"git could not read the worktree"]'

test "$(row removed '.worktree')" = "{\"path\":\"$tmp/removed\",\"branch\":\"feat/removed\",\"exists\":false}"
test "$(check removed clean)" = '[null,"worktree missing"]'

# An unparseable Settle: line counts as none.
test "$(row failed '[.worktree, .settle.verdict, .verdict, .stallReasons]')" = '[null,"unclear","stalled",["run failed"]]'
test "$(check failed run)" = '[false,"failed"]'
# Idle past --stale-hours with no Settle: line: a long silence.
test "$(row quiet '[.idleSince, .verdict, .stallReasons]')" = "[\"$old\",\"stalled\",[\"idle 72h\"]]"
test "$(status --stale-hours 100 quiet | jq -c '.threads[0] | [.verdict, .stallReasons]')" = '["not-yet",[]]'

test "$(row waits '[.verdict, .waitingOn]')" = '["waiting",[{"kind":"monitor","description":"pr-review run 5"}]]'

# The caller's own thread: T3 shows nothing while the run is active, but the
# caller sees its monitor and PR watch, not its running tool call.
test "$(status self | jq -c '.threads[0] | [.verdict, .waitingOn, .idleSince]')" = '["waiting",[],null]'
self=$(status --self self | jq -c '.threads[0]')
test "$(jq -c '[.self, .verdict, .stallReasons, (.waitingOn | sort_by(.description))]' <<<"$self")" = '[true,null,[],[{"kind":"monitor","description":"Watching pull request #6"},{"kind":"monitor","description":"wait for marker"}]]'
test "$(jq -c '[.checks[] | select(.id == "run" or .id == "settle") | .pass, .detail]' <<<"$self")" = '[null,"this run",null,"this reply"]'
# Its previous reply's Settle: line is about to be replaced, so it is left out.
test "$(jq -c '.settle' <<<"$self")" = null

# Nothing was written: not the database, nor any worktree's index.
test "$(sha256sum "$tmp/state.sqlite" "$tmp"/{merged,dirty,gone,squashed,followup,quoted,indent,moved,switched,movedon,offbranch}/.git/index)" = "$before"

# Usage and lookup failures.
if status 2>/dev/null; then exit 1; else test $? = 64; fi
if status "x'y" 2>/dev/null; then exit 1; else test $? = 64; fi
if status --self merged dirty 2>/dev/null; then exit 1; else test $? = 64; fi
if status --stale-hours soon merged 2>/dev/null; then exit 1; else test $? = 64; fi
if status elsewhere 2>"$tmp/err"; then exit 1; else test $? = 2; fi
grep -q 'no readable T3 state database holding thread elsewhere' "$tmp/err"
if status merged elsewhere 2>"$tmp/err"; then exit 1; else test $? = 2; fi
grep -q "no thread elsewhere in $tmp/state.sqlite" "$tmp/err"

# Drift: a thread without the worktree fields, or an assistant message without
# text, means T3's schema moved: fail, don't guess.
sqlite3 "$tmp/state.sqlite" "INSERT INTO orchestration_v2_projection_threads VALUES ('new', 'p1', 'New shape', '$old', '$recent', NULL, NULL, '{$fields,\"activeProviderThreadId\":null}');"
if status merged 2>"$tmp/err"; then exit 1; else test $? = 3; fi
grep -q "lack worktree or branch fields in .*; T3's schema has changed" "$tmp/err"
sqlite3 "$tmp/state.sqlite" "DELETE FROM orchestration_v2_projection_threads WHERE thread_id = 'new';"
sqlite3 "$tmp/state.sqlite" "INSERT INTO orchestration_v2_projection_messages VALUES ('m9', 'merged', 'assistant', 0, '$now', '{\"content\":[]}');"
if status merged 2>"$tmp/err"; then exit 1; else test $? = 3; fi
grep -q "assistant message without text" "$tmp/err"
# The shared checks apply too.
sqlite3 "$tmp/state.sqlite" "DELETE FROM orchestration_v2_projection_messages WHERE message_id = 'm9';"
sqlite3 "$tmp/state.sqlite" "UPDATE orchestration_v2_projection_threads SET payload_json = json_remove(payload_json, '\$.settledOverride') WHERE thread_id = 'quiet';"
if status merged 2>"$tmp/err"; then exit 1; else test $? = 3; fi
grep -q "lack settlement, lineage or provider fields" "$tmp/err"

echo "t3-thread-status tests passed"
