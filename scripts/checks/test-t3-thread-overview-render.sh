#!/usr/bin/env bash
# Contract tests for the T3 thread overview renderer (ADR-0091).
set -euo pipefail

dir=modules/home-manager/programs/ai
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# The Nix wrapper prepends these settings; do the same here.
render_with() {
  {
    echo 'set -euo pipefail'
    echo "overview_template=$1"
    cat "$dir/t3-page.sh" "$dir/t3-thread-overview-render.sh"
  } >"$tmp/render"
}
render_with "$PWD/$dir/skills/t3-thread-overview/template.html"

# Hostile text in titles and summaries must not close the script element.
cat >"$tmp/report.json" <<'JSON'
{"generatedAt": "2026-10-10T12:00:00Z", "windowDays": 3, "source": "test", "readerModel": "test",
 "threads": [{"threadId": "t1", "title": "</script><script>alert(1)</script>", "project": "p",
   "bucket": "unsettled", "status": "idle", "updatedAt": "2026-10-10T11:00:00Z", "createdAt": "2026-10-01T00:00:00Z",
   "prs": [{"url": "https://forge.invalid/pulls/1", "state": "merged"}, {"url": "https://forge.invalid/pulls/2", "state": "open"}],
   "progressPct": 40, "phase": "implementing", "owner": "agent", "goal": "Goal with <b>markup</b>",
   "nextAction": "Continue", "done": [], "remaining": [], "blocker": null, "flag": null,
   "verdict": null, "verdictReason": null,
   "waitingOn": [{"kind": "monitor", "description": "pr-review run 1"}]}]}
JSON
bash "$tmp/render" "$tmp/report.json" "$tmp/page.html"
[[ $(grep -c '</script>' "$tmp/page.html") == 1 ]] || fail "report text closed the script element"
page=$(<"$tmp/page.html")
[[ "$page" == *'\u003c/script>\u003cscript>alert(1)'* ]] || fail "< was not escaped as \\u003c"
grep -qF '"threadId":"t1"' "$tmp/page.html" || fail "report JSON missing"
if grep -qF 'sample-1' "$tmp/page.html"; then fail "template sample data kept"; fi
# Only what the page shows is embedded: open PRs, no inventory timestamps.
if grep -qF -e 'pulls/1"' -e createdAt "$tmp/page.html"; then fail "unused fields were kept"; fi
grep -qF 'pulls/2"' "$tmp/page.html" || fail "open PR was dropped"
[[ $(grep -c 'REPORT-START' "$tmp/page.html") == 1 ]] || fail "markers not preserved once"

# The page's script parses, and the report round-trips through it.
sed -n '/^<script>$/,/^<\/script>$/p' "$tmp/page.html" | sed '1d;$d' >"$tmp/page.js"
node --check "$tmp/page.js" || fail "rendered script does not parse"
title=$(node -e '
  const src = require("fs").readFileSync(process.argv[1], "utf8");
  const json = src.split("/*REPORT-START*/")[1].split("/*REPORT-END*/")[0];
  console.log(JSON.parse(json).threads[0].title);
' "$tmp/page.js")
[[ "$title" == '</script><script>alert(1)</script>' ]] || fail "title did not round-trip: $title"

# t3-thread-status facts join by thread ID: the thread's own Settle: line
# beats the reader's phase, and a thread that never handed off is stalled.
cat >"$tmp/facts-report.json" <<'JSON'
{"generatedAt": "2026-10-10T12:00:00Z", "windowDays": 3, "source": "test", "readerModel": "test",
 "threads": [
   {"threadId": "said-ready", "title": "A", "project": "p", "bucket": "unsettled", "phase": "implementing", "owner": "agent", "waitingOn": []},
   {"threadId": "stalled", "title": "B", "project": "p", "bucket": "unsettled", "phase": "done-not-settled", "owner": "user", "waitingOn": []},
   {"threadId": "said-not-yet", "title": "C", "project": "p", "bucket": "unsettled", "phase": "done-not-settled", "owner": "user", "waitingOn": []},
   {"threadId": "no-facts", "title": "D", "project": "p", "bucket": "unsettled", "phase": "done-not-settled", "owner": "user", "waitingOn": []},
   {"threadId": "running", "title": "E", "project": "p", "bucket": "unsettled", "phase": "done-not-settled", "owner": "user", "waitingOn": []},
   {"threadId": "says-agent", "title": "F", "project": "p", "bucket": "unsettled", "phase": "implementing", "owner": "user", "waitingOn": []},
   {"threadId": "quiet", "title": "G", "project": "p", "bucket": "unsettled", "phase": "awaiting-user", "owner": "user", "waitingOn": []},
   {"threadId": "quiet-done", "title": "H", "project": "p", "bucket": "unsettled", "phase": "done-not-settled", "owner": "user", "waitingOn": []}]}
JSON
cat >"$tmp/facts.json" <<'JSON'
{"database": "/x", "generatedAt": "2026-10-10T12:00:00Z", "threads": [
  {"threadId": "said-ready", "verdict": "ready", "stallReasons": [], "settle": {"verdict": "ready", "line": "ready.", "stale": false, "at": "x"}, "worktree": {"path": "/private/path"}},
  {"threadId": "stalled", "verdict": "stalled", "stallReasons": ["uncommitted changes"], "settle": null},
  {"threadId": "said-not-yet", "verdict": "not-yet", "stallReasons": [], "settle": {"verdict": "not-yet", "line": "not yet: <deploy>, user", "owner": "user", "stale": false}},
  {"threadId": "running", "verdict": "waiting", "stallReasons": [], "settle": null},
  {"threadId": "says-agent", "verdict": "not-yet", "stallReasons": [], "settle": {"verdict": "not-yet", "line": "not yet: CI, agent", "owner": "agent", "stale": false}},
  {"threadId": "quiet", "verdict": "stalled", "stallReasons": ["idle 30h"], "settle": null},
  {"threadId": "quiet-done", "verdict": "stalled", "stallReasons": ["idle 30h"], "settle": null}]}
JSON
bash "$tmp/render" "$tmp/facts-report.json" "$tmp/facts.html" "$tmp/facts.json"
if grep -qF /private/path "$tmp/facts.html"; then fail "unused status fields were kept"; fi
sed -n '/^<script>$/,/^<\/script>$/p' "$tmp/facts.html" | sed '1d;$d' >"$tmp/facts.js"
groups=$(node -e '
  let html = "";
  globalThis.document = { getElementById: () => ({ insertAdjacentHTML: (_, h) => { html += h; } }) };
  require(process.argv[1]);
  const order = [...html.matchAll(/<h3>.*?<\/span>([^<·]+)·[^<]*<\/h3>|href="t3-thread:\/\/v1\/([^"]+)"/g)]
    .map(m => (m[1] ? "#" + m[1].trim() : m[2]));
  console.log(order.join(" "));
  if (!html.includes("Settle: not yet: &lt;deploy&gt;, user")) process.exit(2);
  if ((html.match(/chip stalled/g) || []).length !== 3) process.exit(3);
' "$tmp/facts.js") || fail "page script failed or did not escape the Settle: line"
# A running thread is waiting, whatever its reader says; the owner a thread
# names wins; a thread that only went quiet on you stays under "Waiting on
# you", even when its reader thinks it is done.
[[ "$groups" == "#Waiting on you said-not-yet quiet quiet-done #Stalled stalled #Agent can continue says-agent #Agent working or waiting on background work running #Ready to settle said-ready no-facts" ]] ||
  fail "unexpected grouping: $groups"
echo '{"threads": [{"threadId": "x"}]}' >"$tmp/bad-facts.json"
status=0
bash "$tmp/render" "$tmp/facts-report.json" "$tmp/bad.html" "$tmp/bad-facts.json" 2>/dev/null || status=$?
[[ "$status" == 65 && ! -e "$tmp/bad.html" ]] || fail "malformed status file exited $status"

# Malformed reports are rejected without writing the page.
status=0
echo '{"threads": [{"title": "no id"}]}' >"$tmp/bad.json"
bash "$tmp/render" "$tmp/bad.json" "$tmp/bad.html" 2>/dev/null || status=$?
[[ "$status" == 65 && ! -e "$tmp/bad.html" ]] || fail "malformed report exited $status"
status=0
echo 'not json' >"$tmp/bad.json"
bash "$tmp/render" "$tmp/bad.json" "$tmp/bad.html" 2>/dev/null || status=$?
[[ "$status" == 65 ]] || fail "invalid JSON exited $status"

# Two concatenated reports, or fields the page would choke on, are rejected.
bad_report() {
  local status=0
  printf '%s\n' "$1" >"$tmp/bad.json"
  bash "$tmp/render" "$tmp/bad.json" "$tmp/bad.html" 2>/dev/null || status=$?
  [[ "$status" == 65 ]] || fail "$2 exited $status"
}
bad_report "$(cat "$tmp/report.json" "$tmp/report.json")" "concatenated reports"
bad_report '{"threads": []}' "missing generatedAt"
bad_report '{"generatedAt": "x", "threads": [{"threadId": "a", "done": "one item"}]}' "string done list"
bad_report '{"generatedAt": "x", "threads": [{"threadId": "a", "prs": {}}]}' "object prs"
bad_report '{"generatedAt": "x", "threads": [{"threadId": "a", "waitingOn": "monitor"}]}' "string waitingOn"

# A template without exactly one marker block, in order, is refused.
printf '<script>/*REPORT-START*/{}/*REPORT-END*/ /*REPORT-START*/</script>\n' >"$tmp/twice.html"
render_with "$tmp/twice.html"
status=0
bash "$tmp/render" "$tmp/report.json" "$tmp/out.html" 2>/dev/null || status=$?
[[ "$status" == 70 ]] || fail "duplicate markers exited $status"
for template in '/*REPORT-START*/{}/*REPORT-END*//*REPORT-END*/' '/*REPORT-END*/{}/*REPORT-START*/' '/*REPORT-START*/{}'; do
  printf '%s\n' "$template" >"$tmp/bad-template.html"
  render_with "$tmp/bad-template.html"
  status=0
  bash "$tmp/render" "$tmp/report.json" "$tmp/out.html" 2>/dev/null || status=$?
  [[ "$status" == 70 ]] || fail "template $template exited $status"
done
render_with "$PWD/$dir/skills/t3-thread-overview/template.html"

# Usage errors exit 64.
status=0
bash "$tmp/render" "$tmp/report.json" 2>/dev/null || status=$?
[[ "$status" == 64 ]] || fail "usage error exited $status"

echo "t3 thread overview render: ok"
