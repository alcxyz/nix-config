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
    cat "$dir/t3-thread-overview-render.sh"
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
   "verdict": null, "verdictReason": null}]}
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
