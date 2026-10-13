#!/usr/bin/env bash
# Contract tests for the T3 thread status card renderer (ADR-0091).
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
  echo "status_card=$PWD/$dir/t3-thread-status-card.html"
  cat "$dir/t3-page.sh" "$dir/t3-thread-status-render.sh"
} >"$tmp/render"
render() { bash "$tmp/render" "$@"; }

# Hostile text in the title and notes must not close the script element.
cat >"$tmp/status.json" <<'JSON'
{"database": "/x", "generatedAt": "2026-10-11T12:00:00Z", "threads": [{"threadId": "t1",
  "project": "p", "title": "</script><script>alert(1)</script>", "state": "unsettled",
  "run": {"status": "completed", "active": false, "requestedAt": "x", "completedAt": "x"},
  "idleSince": "x", "idleMinutes": 30, "self": false, "verdict": "stalled", "stallReasons": ["uncommitted changes"],
  "waitingOn": [], "prs": [{"url": "https://forge.invalid/pulls/2", "number": 2, "state": "open", "baseBranch": "dev", "watched": true}],
  "lastUserAt": null, "createdAt": "x", "updatedAt": "x", "settle": null,
  "worktree": {"path": "/private/path", "branch": "feat/x", "exists": true, "changed": 1},
  "checks": [{"id": "clean", "label": "No uncommitted changes", "pass": false, "detail": "1 changed, 0 untracked"}]}]}
JSON
echo '{"summary": "<b>half</b> done", "remaining": ["Commit the change"], "owner": "agent"}' >"$tmp/notes.json"
render "$tmp/status.json" "$tmp/notes.json" "$tmp/card.html"
[[ $(grep -c '</script>' "$tmp/card.html") == 1 ]] || fail "report text closed the script element"
if grep -qF -e sample-1 -e /private/path -e createdAt "$tmp/card.html"; then fail "unused fields or sample data kept"; fi

# The script parses, and the report round-trips with the script's verdict.
sed -n '/^<script>$/,/^<\/script>$/p' "$tmp/card.html" | sed '1d;$d' >"$tmp/card.js"
node --check "$tmp/card.js" || fail "rendered script does not parse"
got=$(node -e '
  const src = require("fs").readFileSync(process.argv[1], "utf8");
  const r = JSON.parse(src.split("/*REPORT-START*/")[1].split("/*REPORT-END*/")[0]);
  console.log(JSON.stringify([r.verdict, r.thread.title, r.summary, r.remaining, r.leftForYou, r.thread.worktree]));
' "$tmp/card.js")
[[ "$got" == '["stalled","</script><script>alert(1)</script>","<b>half</b> done",["Commit the change"],[],{"branch":"feat/x","head":null,"exists":true}]' ]] ||
  fail "report did not round-trip: $got"

# The agent's verdict wins; a --self report must give one.
echo '{"verdict": "not-yet"}' >"$tmp/notes.json"
render "$tmp/status.json" "$tmp/notes.json" "$tmp/card.html"
grep -qF '"verdict":"not-yet"' "$tmp/card.html" || fail "notes verdict ignored"
bad() {
  local status=0
  render "$1" "$2" "$tmp/bad.html" 2>/dev/null || status=$?
  [[ "$status" == 65 && ! -e "$tmp/bad.html" ]] || fail "$3 exited $status"
}
jq '.threads[0] |= (.self = true | .verdict = null)' "$tmp/status.json" >"$tmp/self.json"
echo '{}' >"$tmp/empty.json"
bad "$tmp/self.json" "$tmp/empty.json" "self report without a verdict"
echo '{"verdict": "done"}' >"$tmp/notes.json"
bad "$tmp/status.json" "$tmp/notes.json" "unknown verdict"
# A settled thread keeps the script's verdict, and its own Left for you: line
# fills the card's list unless the notes give one.
jq '.threads[0] |= (.state = "settled" | .verdict = "left-for-you" | .settle = {verdict: "ready", line: "ready.", stale: false, leftForYou: "deploy"})' \
  "$tmp/status.json" >"$tmp/settled.json"
bash "$tmp/render" "$tmp/settled.json" "$tmp/empty.json" "$tmp/settled.html"
grep -qF '"verdict":"left-for-you"' "$tmp/settled.html" || fail "settled verdict lost"
grep -qF '"leftForYou":["deploy"]' "$tmp/settled.html" || fail "Left for you: line not used"
# Notes cannot give a settled thread a live verdict.
echo '{"verdict": "ready"}' >"$tmp/notes.json"
bad "$tmp/settled.json" "$tmp/notes.json" "live verdict for a settled thread"
# Not once a user message has come after it, nor for a live thread.
jq '.threads[0].settle.stale = true' "$tmp/settled.json" >"$tmp/stale.json"
bash "$tmp/render" "$tmp/stale.json" "$tmp/empty.json" "$tmp/stale.html"
grep -qF '"leftForYou":[]' "$tmp/stale.html" || fail "stale Left for you: line used"
jq '.threads[0] |= (.state = "unsettled" | .verdict = "ready")' "$tmp/settled.json" >"$tmp/live.json"
bash "$tmp/render" "$tmp/live.json" "$tmp/empty.json" "$tmp/live.html"
grep -qF '"leftForYou":[]' "$tmp/live.html" || fail "live thread's Left for you: line used"
echo '{"remaining": "one item"}' >"$tmp/notes.json"
bad "$tmp/status.json" "$tmp/notes.json" "string remaining"
echo '{"owner": "someone"}' >"$tmp/notes.json"
bad "$tmp/status.json" "$tmp/notes.json" "unknown owner"
jq '.threads += .threads' "$tmp/status.json" >"$tmp/two.json"
bad "$tmp/two.json" "$tmp/empty.json" "two threads"
echo 'not json' >"$tmp/broken.json"
bad "$tmp/broken.json" "$tmp/empty.json" "invalid status JSON"
bad "$tmp/status.json" "$tmp/broken.json" "invalid notes JSON"

status=0
render "$tmp/status.json" "$tmp/empty.json" 2>/dev/null || status=$?
[[ "$status" == 64 ]] || fail "usage error exited $status"

echo "t3 thread status render: ok"
