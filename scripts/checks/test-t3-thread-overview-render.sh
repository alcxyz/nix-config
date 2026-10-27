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
    echo "overview_group_jq=$PWD/$dir/t3-thread-overview-group.jq"
    cat "$dir/t3-page.sh" "$dir/t3-thread-overview-lib.sh" "$dir/t3-thread-overview-render.sh"
  } >"$tmp/render"
}
render_with "$PWD/$dir/t3-thread-overview.html"

# page_script PAGE: the page's script, for node.
page_script() {
  sed -n '/^<script>$/,/^<\/script>$/p' "$1" | sed '1d;$d' >"$1.js"
  node --check "$1.js" || fail "script in $1 does not parse"
}
# page_html PAGE [HREF]: run the page's script against a stub DOM, served
# from HREF if given, and print its HTML.
page_html() {
  page_script "$1"
  node -e '
    if (process.argv[2]) globalThis.location = { href: process.argv[2] };
    let html = "";
    const app = { set innerHTML(h) { html = h; }, addEventListener() {}, querySelectorAll: () => [] };
    globalThis.document = { getElementById: id => (id === "app" ? app : null) };
    require(process.argv[1]);
    process.stdout.write(html);
  ' "$1.js" "${2:-}" || fail "script in $1 failed"
}

# Hostile text in titles and summaries must not close the script element.
cat >"$tmp/report.json" <<'JSON'
{"generatedAt": "2026-10-10T12:00:00Z", "windowDays": 3, "source": "test", "readerModel": "test", "environmentId": "env 1",
 "threads": [{"threadId": "mcp:t1", "title": "</script><script>alert(1)</script>", "project": "p",
   "bucket": "unsettled", "status": "idle", "updatedAt": "2026-10-10T11:00:00Z", "createdAt": "2026-10-01T00:00:00Z",
   "prs": [{"url": "https://forge.invalid/pulls/1", "state": "merged"}, {"url": "https://forge.invalid/pulls/2", "state": "open"}],
   "pendingUnwatched": ["https://forge.invalid/pulls/2"],
   "progressPct": "40", "phase": "implementing", "owner": "agent", "goal": "Goal with <b>markup</b>",
   "nextAction": "Continue", "done": [], "remaining": [], "blocker": null, "flag": null,
   "verdict": null, "verdictReason": null,
   "waitingOn": [{"kind": "monitor", "description": "pr-review run 1"}]}]}
JSON
bash "$tmp/render" "$tmp/report.json" "$tmp/one"
[[ $(jq -c '[.[] | [(.file | sub(".*/"; "")), .title, .height]]' "$tmp/one/pages.json") == '[["1-agent.html","T3 threads: Agent side, no action from you (1)",640]]' ]] ||
  fail "unexpected manifest: $(cat "$tmp/one/pages.json")"
page_file=$(jq -r '.[0].file' "$tmp/one/pages.json")
[[ "$page_file" == "$tmp/one/1-agent.html" ]] || fail "manifest path is not absolute: $page_file"
[[ $(grep -c '</script>' "$page_file") == 1 ]] || fail "report text closed the script element"
page=$(<"$page_file")
[[ "$page" == *'\u003c/script>\u003cscript>alert(1)'* ]] || fail "< was not escaped as \\u003c"
grep -qF '"threadId":"mcp:t1"' "$page_file" || fail "report JSON missing"
if grep -qF 'sample-1' "$page_file"; then fail "template sample data kept"; fi
# Only what the page shows is embedded: open PRs, no inventory timestamps.
if grep -qF -e 'pulls/1"' -e createdAt "$page_file"; then fail "unused fields were kept"; fi
grep -qF 'pulls/2"' "$page_file" || fail "open PR was dropped"
[[ $(grep -c 'REPORT-START' "$page_file") == 1 ]] || fail "markers not preserved once"

# The page's script parses, and the report round-trips through it.
page_script "$page_file"
fields=$(node -e '
  const src = require("fs").readFileSync(process.argv[1], "utf8");
  const r = JSON.parse(src.split("/*REPORT-START*/")[1].split("/*REPORT-END*/")[0]);
  console.log(JSON.stringify([r.threads[0].title, r.threads[0].progressPct, r.threads[0].group, !!r.summary, !!r.footer]));
' "$page_file.js")
[[ "$fields" == '["</script><script>alert(1)</script>",40,"waiting",true,true]' ]] ||
  fail "report did not round-trip: $fields"
html=$(page_html "$page_file")
[[ "$html" == *'&lt;/script&gt;&lt;script&gt;alert(1)'* && "$html" == *'Goal with &lt;b&gt;markup'* ]] ||
  fail "page did not escape reader text"
# Thread links point at the thread's route on the T3 server serving the page,
# since T3 opens only http(s) links from a page; without one they stay
# t3-thread:// links.
[[ "$html" == *'href="t3-thread://v1/mcp:t1"'* ]] || fail "no t3-thread link without a server"
html=$(page_html "$page_file" "http://t3.invalid:3773/api/assets/page?token=x")
[[ "$html" == *'href="http://t3.invalid:3773/env%201/mcp%3At1"'* ]] || fail "no app route link"

# t3-thread-status facts join by thread ID: the thread's own Settle: line
# beats the reader's phase, and a thread that never handed off is stalled.
cat >"$tmp/facts-report.json" <<'JSON'
{"generatedAt": "2026-10-10T12:00:00Z", "windowDays": 3, "source": "test", "readerModel": "test",
 "threads": [
   {"threadId": "said-ready", "title": "A", "project": "p", "bucket": "unsettled", "phase": "implementing", "owner": "agent", "waitingOn": []},
   {"threadId": "stalled", "title": "B", "project": "p", "bucket": "unsettled", "phase": "done-not-settled", "owner": "user", "waitingOn": []},
   {"threadId": "said-not-yet", "title": "C", "project": "p", "bucket": "unsettled", "phase": "done-not-settled", "owner": "user", "actionKind": "deploy", "waitingOn": []},
   {"threadId": "no-facts", "title": "D", "project": "p", "bucket": "unsettled", "phase": "done-not-settled", "owner": "user", "waitingOn": []},
   {"threadId": "running", "title": "E", "project": "p", "bucket": "unsettled", "phase": "done-not-settled", "owner": "user", "waitingOn": []},
   {"threadId": "says-agent", "title": "F", "project": "p", "bucket": "unsettled", "phase": "implementing", "owner": "user", "waitingOn": []},
   {"threadId": "quiet", "title": "G", "project": "p", "bucket": "unsettled", "phase": "awaiting-user", "owner": "user", "actionKind": "decide", "waitingOn": []},
   {"threadId": "quiet-done", "title": "H", "project": "p", "bucket": "unsettled", "phase": "done-not-settled", "owner": "user", "actionKind": "<bogus>", "waitingOn": []},
   {"threadId": "s-done", "title": "I", "project": "p", "bucket": "recently-settled", "waitingOn": []},
   {"threadId": "s-left", "title": "J", "project": "p", "bucket": "recently-settled", "settledAt": "2026-10-09T10:00:00.000Z", "waitingOn": []},
   {"threadId": "s-reader", "title": "K", "project": "p", "bucket": "recently-settled", "progressPct": 100, "verdict": "done", "waitingOn": []},
   {"threadId": "s-check", "title": "L", "project": "p", "bucket": "recently-settled", "settledAt": "2026-10-09T11:00:00.000Z", "progressPct": 80, "verdict": "follow-up", "waitingOn": []},
   {"threadId": "s-ack", "title": "M", "project": "p", "bucket": "recently-settled", "progressPct": 80, "verdict": "follow-up", "acknowledged": true, "waitingOn": []}]}
JSON
cat >"$tmp/facts.json" <<'JSON'
{"database": "/x", "generatedAt": "2026-10-10T12:00:00Z", "threads": [
  {"threadId": "said-ready", "verdict": "ready", "stallReasons": [], "settle": {"verdict": "ready", "line": "ready.", "stale": false, "at": "x"}, "worktree": {"path": "/private/path"}},
  {"threadId": "stalled", "verdict": "stalled", "stallReasons": ["uncommitted changes"], "settle": null},
  {"threadId": "said-not-yet", "verdict": "not-yet", "stallReasons": [], "settle": {"verdict": "not-yet", "line": "not yet: <deploy>, user", "owner": "user", "stale": false}},
  {"threadId": "running", "verdict": "waiting", "stallReasons": [], "settle": null},
  {"threadId": "says-agent", "verdict": "not-yet", "stallReasons": [], "settle": {"verdict": "not-yet", "line": "not yet: CI, agent", "owner": "agent", "stale": false}},
  {"threadId": "quiet", "verdict": "stalled", "stallReasons": ["idle 30h"], "settle": null},
  {"threadId": "quiet-done", "verdict": "stalled", "stallReasons": ["idle 30h"], "settle": null},
  {"threadId": "s-done", "verdict": "done", "stallReasons": [], "settle": {"verdict": "ready", "line": "ready.", "stale": false, "leftForYou": null}},
  {"threadId": "s-left", "verdict": "left-for-you", "stallReasons": [], "settle": {"verdict": "ready", "line": "ready.", "stale": false, "leftForYou": "<deploy>"}},
  {"threadId": "s-reader", "verdict": "check", "stallReasons": [], "settle": null},
  {"threadId": "s-check", "verdict": "check", "stallReasons": [], "settle": null}]}
JSON
bash "$tmp/render" "$tmp/facts-report.json" "$tmp/facts" "$tmp/facts.json"
if grep -rqF /private/path "$tmp/facts"; then fail "unused status fields were kept"; fi
sections=$(jq -r '.[].file' "$tmp/facts/pages.json" | while read -r f; do
  page_script "$f"
  node -e '
    const src = require("fs").readFileSync(process.argv[1], "utf8");
    const r = JSON.parse(src.split("/*REPORT-START*/")[1].split("/*REPORT-END*/")[0]);
    console.log(r.section.key + ":" + r.threads.map(t => t.threadId + "=" + t.group).join(","));
  ' "$f.js"
done | paste -sd' ')
# A running thread is waiting, whatever its reader says; the owner a thread
# names wins; a thread that only went quiet on you stays under "Waiting on
# you", even when its reader thinks it is done. A settled thread whose facts
# agree with its Settle: ready line is done without a reader, unless it left
# steps for the user, which become its next step; one the user acknowledged
# is done; the rest follow the reader. Each page holds only its section.
[[ "$sections" == "you:said-not-yet=user,quiet=user,quiet-done=user stalled:stalled=stalled settle:said-ready=settle,no-facts=settle settled:s-done=settled-done,s-left=settled-open,s-reader=settled-done,s-check=settled-open,s-ack=settled-done agent:running=waiting,says-agent=agent" ]] ||
  fail "unexpected sections: $sections"
[[ $(jq -r '[.[].file | sub(".*/"; "")] | join(" ")' "$tmp/facts/pages.json") == "1-you.html 2-stalled.html 3-settle.html 4-settled.html 5-agent.html" ]] ||
  fail "unexpected page files"

# t3-thread-overview-group prints the same grouping as JSON for the deck
# dashboard, with the counts once and every report field but the threads.
{
  echo 'set -euo pipefail'
  echo "overview_group_jq=$PWD/$dir/t3-thread-overview-group.jq"
  cat "$dir/t3-thread-overview-lib.sh" "$dir/t3-thread-overview-group.sh"
} >"$tmp/group"
grouped=$(bash "$tmp/group" "$tmp/facts-report.json" "$tmp/facts.json")
[[ $(jq -r '[.sections[] | .key + ":" + ([.threads[] | .threadId + "=" + .group] | join(","))] | join(" ")' <<<"$grouped") == "$sections" ]] ||
  fail "group command disagrees with the pages: $grouped"
[[ $(jq -c '[.source, .windowDays, .summary.user, .summary.settledOpen, (.threads | type), .sections[3].title]' <<<"$grouped") == '["test",3,3,2,"null","Settled in the last 3 days"]' ]] ||
  fail "unexpected group report fields: $grouped"
[[ $(jq -r '.sections[0].threads[0].facts.settle.line' <<<"$grouped") == "not yet: <deploy>, user" ]] ||
  fail "group command lost the facts"
# A thread that stopped while an open PR's checks run, with nothing to wake
# it, is flagged; a watch, other waiting work or a live run clears the flag.
jq -c '.threads[0].waitingOn = []' "$tmp/report.json" >"$tmp/unwatched.json"
flagged=$(bash "$tmp/group" "$tmp/unwatched.json")
[[ $(jq -c '[.sections[].threads[].unwatchedChecks, .summary.unwatchedChecks]' <<<"$flagged") == '[["https://forge.invalid/pulls/2"],1]' ]] ||
  fail "stopped thread with unwatched pending checks was not flagged: $flagged"
for change in '.threads[0].pendingUnwatched = []' '.threads[0].status = "running"' '.threads[0].bucket = "recently-settled"'; do
  jq -c "$change" "$tmp/unwatched.json" >"$tmp/watched.json"
  [[ $(bash "$tmp/group" "$tmp/watched.json" | jq -c '[.sections[].threads[].unwatchedChecks, .summary.unwatchedChecks]') == '[[],0]' ]] ||
    fail "flagged after $change"
done
[[ $(bash "$tmp/group" "$tmp/report.json" | jq -c '[.sections[].threads[].unwatchedChecks]') == '[[]]' ]] ||
  fail "a thread waiting on a monitor was flagged"
bash "$tmp/render" "$tmp/unwatched.json" "$tmp/unwatched"
html=$(page_html "$(jq -r '.[0].file' "$tmp/unwatched/pages.json")")
[[ "$html" == *'PR 2: checks pending, unwatched'* && "$html" == *'stopped, PR checks unwatched'* ]] ||
  fail "page does not show the unwatched checks flag"
echo '{"generatedAt": "2026-10-10T12:00:00Z", "windowDays": 3, "threads": []}' >"$tmp/group-empty.json"
[[ $(bash "$tmp/group" "$tmp/group-empty.json" | jq -c '[.sections, .summary.unsettled]') == '[[],0]' ]] ||
  fail "empty report did not group to no sections"
for args in "$tmp/bad-group.json" "$tmp/facts-report.json $tmp/bad-group.json"; do
  echo '{"threads": [{"title": "no id"}]}' >"$tmp/bad-group.json"
  status=0
  # shellcheck disable=SC2086 # two file arguments on purpose
  bash "$tmp/group" $args >/dev/null 2>&1 || status=$?
  [[ "$status" == 65 ]] || fail "group command on $args exited $status"
done
status=0
bash "$tmp/group" >/dev/null 2>&1 || status=$?
[[ "$status" == 64 ]] || fail "group command without arguments exited $status"

you=$(page_html "$tmp/facts/1-you.html")
[[ "$you" == *'class="kpis"'* && "$you" != *'class="note"'* ]] || fail "counts not on the first page only"
[[ "$you" == *"Settle: not yet: &lt;deploy&gt;, user"* ]] || fail "Settle: line not shown escaped"
[[ "$you" == *"stalled: idle 30h"* ]] || fail "stalled chip missing"
# Waiting on you is split by what the user has to do; unknown kinds are Other.
order=$(grep -o '<h3>[^<]*</h3>' <<<"$you" | paste -sd'|')
[[ "$order" == "<h3>Decide or answer · 1</h3>|<h3>Deploy or verify · 1</h3>|<h3>Other · 1</h3>" ]] ||
  fail "unexpected action groups: $order"
settled=$(page_html "$tmp/facts/4-settled.html")
[[ "$settled" == *'</span>&lt;deploy&gt;</div>'* ]] || fail "left-for-you step is not the next step"
# Only threads that may not be done get a checkbox, carrying their settle time.
acks=$(grep -o 'data-ack="[^"]*"' <<<"$settled" | paste -sd' ')
[[ "$acks" == 'data-ack="s-left@2026-10-09T10:00:00.000Z" data-ack="s-check@2026-10-09T11:00:00.000Z"' ]] ||
  fail "unexpected checkboxes: $acks"
[[ "$settled" == *"you marked it done"* ]] || fail "acknowledged thread not explained"
agent=$(page_html "$tmp/facts/5-agent.html")
[[ "$agent" == *'class="note"'* && "$agent" != *'class="kpis"'* ]] || fail "footer not on the last page only"

# No threads still gives one page, with the counts.
echo '{"generatedAt": "2026-10-10T12:00:00Z", "windowDays": 3, "threads": []}' >"$tmp/empty.json"
bash "$tmp/render" "$tmp/empty.json" "$tmp/empty"
[[ $(jq -r '[.[].file | sub(".*/"; "")] | join(" ")' "$tmp/empty/pages.json") == "1-summary.html" ]] || fail "empty report pages"
[[ $(page_html "$tmp/empty/1-summary.html") == *"No unsettled or recently settled threads."* ]] || fail "empty page text"

echo '{"threads": [{"threadId": "x"}]}' >"$tmp/bad-facts.json"
status=0
bash "$tmp/render" "$tmp/facts-report.json" "$tmp/bad" "$tmp/bad-facts.json" 2>/dev/null || status=$?
[[ "$status" == 65 && ! -e "$tmp/bad" ]] || fail "malformed status file exited $status"

# Malformed reports are rejected without writing pages.
status=0
echo '{"threads": [{"title": "no id"}]}' >"$tmp/bad.json"
bash "$tmp/render" "$tmp/bad.json" "$tmp/bad" 2>/dev/null || status=$?
[[ "$status" == 65 && ! -e "$tmp/bad" ]] || fail "malformed report exited $status"
status=0
echo 'not json' >"$tmp/bad.json"
bash "$tmp/render" "$tmp/bad.json" "$tmp/bad" 2>/dev/null || status=$?
[[ "$status" == 65 ]] || fail "invalid JSON exited $status"

# Two concatenated reports, or fields the page would choke on, are rejected.
bad_report() {
  local status=0
  printf '%s\n' "$1" >"$tmp/bad.json"
  bash "$tmp/render" "$tmp/bad.json" "$tmp/bad" 2>/dev/null || status=$?
  [[ "$status" == 65 ]] || fail "$2 exited $status"
}
bad_report "$(cat "$tmp/report.json" "$tmp/report.json")" "concatenated reports"
bad_report '{"threads": []}' "missing generatedAt"
bad_report '{"generatedAt": "x", "threads": [{"threadId": "a", "done": "one item"}]}' "string done list"
bad_report '{"generatedAt": "x", "threads": [{"threadId": "a", "prs": {}}]}' "object prs"
bad_report '{"generatedAt": "x", "threads": [{"threadId": "a", "waitingOn": "monitor"}]}' "string waitingOn"
bad_report '{"generatedAt": "x", "environmentId": 7, "threads": []}' "numeric environmentId"

# A template without exactly one marker block, in order, is refused.
printf '<script>/*REPORT-START*/{}/*REPORT-END*/ /*REPORT-START*/</script>\n' >"$tmp/twice.html"
render_with "$tmp/twice.html"
status=0
bash "$tmp/render" "$tmp/report.json" "$tmp/out" 2>/dev/null || status=$?
[[ "$status" == 70 ]] || fail "duplicate markers exited $status"
for template in '/*REPORT-START*/{}/*REPORT-END*//*REPORT-END*/' '/*REPORT-END*/{}/*REPORT-START*/' '/*REPORT-START*/{}'; do
  printf '%s\n' "$template" >"$tmp/bad-template.html"
  render_with "$tmp/bad-template.html"
  status=0
  bash "$tmp/render" "$tmp/report.json" "$tmp/out" 2>/dev/null || status=$?
  [[ "$status" == 70 ]] || fail "template $template exited $status"
done
render_with "$PWD/$dir/t3-thread-overview.html"

# Usage errors exit 64, including an output path that is a file.
status=0
bash "$tmp/render" "$tmp/report.json" 2>/dev/null || status=$?
[[ "$status" == 64 ]] || fail "usage error exited $status"
status=0
bash "$tmp/render" "$tmp/report.json" "$tmp/report.json" 2>/dev/null || status=$?
[[ "$status" == 64 ]] || fail "file as output directory exited $status"

echo "t3 thread overview render: ok"
