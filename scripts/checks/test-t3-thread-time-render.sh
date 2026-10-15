#!/usr/bin/env bash
# Contract tests for the T3 thread time page renderer (ADR-0091, #676).
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
  echo "time_template=$PWD/$dir/t3-thread-time.html"
  cat "$dir/t3-page.sh" "$dir/t3-thread-time-render.sh"
} >"$tmp/render"
render() { bash "$tmp/render" "$@"; }

# Hostile text in the title, labels and notes must not close the script element.
cat >"$tmp/time.json" <<'JSON'
{"database": "/private/state.sqlite", "generatedAt": "2026-10-11T12:00:00Z", "idleMinutes": 30,
 "threadId": "t1", "title": "</script><script>alert(1)</script>",
 "start": "2026-10-11T09:00:00Z", "end": "2026-10-11T10:00:00Z", "spanSeconds": 3600,
 "activeSeconds": 3000, "agentSeconds": 2400, "waitSeconds": 600, "userSeconds": 300, "idleSeconds": 300,
 "categories": [
   {"category": "coding", "seconds": 2400, "agentSeconds": 2400, "waitSeconds": 0, "share": 0.8, "items": 9, "failed": 1},
   {"category": "review", "seconds": 600, "agentSeconds": 0, "waitSeconds": 600, "share": 0.2, "items": 1, "failed": 0},
   {"category": "deploy", "seconds": 0, "agentSeconds": 0, "waitSeconds": 0, "share": 0, "items": 0, "failed": 0}],
 "churn": {"runs": 3, "userMessages": 2, "steers": 0, "wakeups": 1, "compactions": 0, "interruptedRuns": 0, "failedRuns": 0, "failedItems": 1},
 "reviewRuns": {"total": 1, "prs": 1, "top": [{"target": "example#1", "count": 1}]},
 "repeated": [{"category": "coding", "label": "<img src=x onerror=alert(2)>", "count": 2}],
 "longest": [{"category": "review", "seconds": 600, "label": "pr-review run 1", "at": "2026-10-11T09:30:00Z"}],
 "binMinutes": 30,
 "timeline": [{"start": "2026-10-11T09:00:00Z", "seconds": {"coding": 1500, "user": 300}},
              {"start": "2026-10-11T09:30:00Z", "seconds": {"coding": 900, "review": 600, "idle": 300}}],
 "requests": [{"number": 1, "at": "2026-10-11T09:00:00Z", "intent": "turn_start", "text": "</script>do it",
               "activeSeconds": 3000, "seconds": {"coding": 2400, "review": 600, "user": 300}}]}
JSON
cat >"$tmp/notes.json" <<'JSON'
{"summary": "<b>mostly</b> coding", "hotspots": [{"title": "Review", "detail": "</script>waited"}],
 "suggestions": ["Review sooner"], "requests": [{"number": 1, "note": "the whole change"}]}
JSON
render "$tmp/time.json" "$tmp/notes.json" "$tmp/page.html"
[[ $(grep -c '</script>' "$tmp/page.html") == 1 ]] || fail "report text closed the script element"
if grep -qF -e /private/state.sqlite -e sample-1 "$tmp/page.html"; then fail "unused fields or sample data kept"; fi

# The script parses, and the report round-trips.
sed -n '/^<script>$/,/^<\/script>$/p' "$tmp/page.html" | sed '1d;$d' >"$tmp/page.js"
node --check "$tmp/page.js" || fail "rendered script does not parse"
report() {
  node -e '
    const src = require("fs").readFileSync(process.argv[1], "utf8");
    const r = JSON.parse(src.split("/*REPORT-START*/")[1].split("/*REPORT-END*/")[0]);
    console.log(JSON.stringify(eval(process.argv[2])));
  ' "$1" "$2"
}
got=$(report "$tmp/page.js" '[r.title, r.database, r.notes.summary, r.notes.hotspots[0].detail, r.notes.requests[0].note, r.requests[0].text]')
[[ "$got" == '["</script><script>alert(1)</script>",null,"<b>mostly</b> coding","</script>waited","the whole change","</script>do it"]' ]] ||
  fail "report did not round-trip: $got"
# The page builds no markup from data.
if grep -qE 'innerHTML|insertAdjacentHTML|outerHTML|document\.write' "$dir/t3-thread-time.html"; then
  fail "the page writes markup"
fi

# Without notes, and with empty notes, the page has none.
render "$tmp/time.json" "$tmp/plain.html"
sed -n '/^<script>$/,/^<\/script>$/p' "$tmp/plain.html" | sed '1d;$d' >"$tmp/plain.js"
[[ $(report "$tmp/plain.js" 'r.notes') == null ]] || fail "notes appeared without notes"
echo '{}' >"$tmp/empty.json"
render "$tmp/time.json" "$tmp/empty.json" "$tmp/empty.html"
grep -qF '"notes":null' "$tmp/empty.html" || fail "empty notes not dropped"
# Output from before requests existed still renders.
jq 'del(.requests)' "$tmp/time.json" >"$tmp/old.json"
render "$tmp/old.json" "$tmp/old.html"
grep -qF '"requests":[]' "$tmp/old.html" || fail "missing requests not defaulted"

# bad WHAT INPUT...: rendering INPUT is rejected as invalid, writing nothing.
bad() {
  local what=$1 status=0
  shift
  render "$@" "$tmp/bad.html" 2>/dev/null || status=$?
  [[ "$status" == 65 && ! -e "$tmp/bad.html" ]] || fail "$what exited $status"
}
badtime() {
  jq "$1" "$tmp/time.json" >"$tmp/badtime.json"
  bad "$2" "$tmp/badtime.json"
}
badtime 'del(.threadId)' "no threadId"
badtime '.activeSeconds = "1h"' "string activeSeconds"
badtime '.categories[0].seconds = null' "category without seconds"
badtime '.categories = {}' "object categories"
badtime 'del(.timeline)' "no timeline"
badtime '.requests = {}' "object requests"
badtime '.requests[0].number = "1"' "string request number"
badtime '[.]' "array instead of object"
badnotes() {
  echo "$1" >"$tmp/badnotes.json"
  bad "$2" "$tmp/time.json" "$tmp/badnotes.json"
}
badnotes '{"summary": 1}' "numeric summary"
badnotes '{"hotspots": [{"title": "x"}]}' "hotspot without detail"
badnotes '{"suggestions": "one"}' "string suggestions"
badnotes '{"requests": [{"number": 1}]}' "request note without text"
badnotes '[]' "array notes"
badnotes '{} {}' "two notes objects"
echo 'not json' >"$tmp/broken.json"
bad "invalid time JSON" "$tmp/broken.json"
bad "invalid notes JSON" "$tmp/time.json" "$tmp/broken.json"

for args in "$tmp/time.json" "$tmp/time.json $tmp/notes.json $tmp/x.html extra"; do
  status=0
  # shellcheck disable=SC2086 # split the argument lists on purpose
  render $args 2>/dev/null || status=$?
  [[ "$status" == 64 ]] || fail "usage error ($args) exited $status"
done

echo "t3 thread time render: ok"
