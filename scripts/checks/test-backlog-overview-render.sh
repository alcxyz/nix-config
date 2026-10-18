#!/usr/bin/env bash
# Contract tests for the backlog overview renderer (ADR-0093).
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
  echo "backlog_template=$PWD/$dir/backlog-overview.html"
  cat "$dir/t3-page.sh" "$dir/backlog-overview-render.sh"
} >"$tmp/render"

# Twenty stale issues, seven blocked PRs and fourteen repositories: the page
# keeps the 8 idlest issues, 5 PRs per lane and 12 repositories, and counts the rest.
stale=$(jq -cn '[range(20) | {ref: "me/app#\(100 + .)", title: "stale \(.)", lane: "stale", flags: [],
  idleDays: (50 + .), mergedPrs: [], openPrs: [], status: null}]')
blocked=$(jq -cn '[range(7) | {ref: "me/app#\(200 + .)", title: "blocked \(.)", lane: "blocked", flags: ["conflict"],
  kind: "own", author: "me", ci: "none", idleDays: ., issues: [], thread: null}]')
repos=$(jq -cn '[range(13) | {forge: "forgejo", repo: "me/other\(.)", openIssues: 1, openPrs: 0, actionable: 0,
  issues: {active: 1}, prs: {}, lastActivity: null}]')
jq -n --argjson stale "$stale" --argjson blocked "$blocked" --argjson repos "$repos" '{
  generatedAt: "2026-10-12T12:00:00Z", user: "me", staleDays: 45,
  sources: {forgejo: "https://forge.invalid", github: "ok", threads: "ok"},
  totals: {repos: 1, issues: 23, prs: 1, issueLanes: {}, prLanes: {}},
  repos: [{forge: "forgejo", repo: "me/app", url: "https://forge.invalid/me/app", openIssues: 23, openPrs: 1,
    actionable: 1, issues: {}, prs: {}, lastActivity: "2026-10-12T00:00:00Z", updatedAt: "x"}] + $repos,
  issues: ([
    {ref: "me/app#1", url: "https://forge.invalid/me/app/issues/1", title: "</script><script>alert(1)</script>",
     lane: "close", flags: [], idleDays: 1, checks: {done: 2, total: 2}, openPrs: [], status: null,
     mergedPrs: [range(5) | {ref: "me/app#\(50 + .)", mergedAt: "2026-10-0\(1 + .)T00:00:00Z", closes: false}]},
    {ref: "me/app#2", title: "active, judged", lane: "active", flags: [], idleDays: 2, mergedPrs: [], openPrs: [],
     status: {date: "2026-10-01", ageDays: 11, owner: "me", next: "Decide <b>this</b>"}},
    {ref: "me/app#3", title: "active, not shown", lane: "active", flags: [], idleDays: 3, mergedPrs: [], openPrs: [],
     status: null}
  ] + $stale),
  prs: [{ref: "me/app#9", url: "https://forge.invalid/me/app/pulls/9", title: "a PR", lane: "ready", flags: [],
    kind: "own", author: "me", ci: "success", idleDays: 1, head: "abc", updatedAt: "x", issues: [],
    thread: {threadId: "t1", title: "thread", bucket: "unsettled", status: "idle"}}] + $blocked
}' >"$tmp/inventory.json"
cat >"$tmp/judgements.json" <<'JSON'
{"readerModel": "test", "focus": null,
 "picks": [{"ref": "me/app#9", "why": "Merge it </script>"}],
 "verdicts": [{"ref": "me/app#2", "verdict": "dispatch", "reason": "Clear criteria"},
   {"ref": "me/app#200", "verdict": "drop", "reason": "Superseded"}]}
JSON

bash "$tmp/render" "$tmp/inventory.json" "$tmp/page.html" "$tmp/judgements.json"
[[ $(grep -c '</script>' "$tmp/page.html") == 1 ]] || fail "report text closed the script element"
if grep -qF 'stale 0' "$tmp/page.html"; then fail "the least idle stale issue was kept"; fi
if grep -qF 'Sample ready PR' "$tmp/page.html"; then fail "template sample data kept"; fi
if grep -qF 'active, not shown' "$tmp/page.html"; then fail "an issue needing no decision was embedded"; fi

sed -n '/^<script>$/,/^<\/script>$/p' "$tmp/page.html" | sed '1d;$d' >"$tmp/page.js"
node --check "$tmp/page.js" || fail "rendered script does not parse"
node -e '
  const src = require("fs").readFileSync(process.argv[1], "utf8");
  const r = JSON.parse(src.split("/*REPORT-START*/")[1].split("/*REPORT-END*/")[0]);
  const fail = m => { console.error("FAIL: " + m); process.exit(1); };
  const byRef = Object.fromEntries(r.issues.map(i => [i.ref, i]));
  if (byRef["me/app#1"].title !== "</script><script>alert(1)</script>") fail("title did not round-trip");
  if (byRef["me/app#1"].mergedPrs.length !== 3 || byRef["me/app#1"].mergedCount !== 5) fail("merged PRs not capped at 3");
  if (byRef["me/app#1"].mergedPrs[0] !== "me/app#54") fail("merged PRs not newest first");
  if (byRef["me/app#2"].judged.verdict !== "dispatch" || byRef["me/app#2"].next !== "Decide <b>this</b>") fail("verdict or next lost");
  if (r.issues.filter(i => i.lane === "stale").length !== 8 || r.staleHidden !== 12) fail("stale issues not capped at 8");
  if (byRef["me/app#111"] || !byRef["me/app#112"] || !byRef["me/app#119"]) fail("the idlest stale issues were not kept");
  const blocked = r.prs.filter(p => p.lane === "blocked").map(p => p.ref);
  if (blocked.length !== 6 || r.prsHidden.blocked !== 1 || !blocked.includes("me/app#206") || blocked.includes("me/app#201"))
    fail("blocked PRs not capped at the 5 idlest");
  const judgedPr = r.prs.find(p => p.ref === "me/app#200");
  if (!judgedPr || judgedPr.judged.verdict !== "drop") fail("a judged PR beyond the cap was dropped");
  if (r.picks[0].pr !== true) fail("a picked PR is not marked as a PR");
  if (r.repos.length !== 12 || r.reposHidden !== 2 || r.repos[0].repo !== "me/app") fail("repositories not capped at 12");
  if (r.picks[0].title !== "a PR" || r.prs.find(p => p.ref === "me/app#9").thread.threadId !== "t1") fail("pick or thread lost");
  const pr = r.prs.find(p => p.ref === "me/app#9");
  if ("url" in pr || "head" in pr || "url" in r.repos[0] || "updatedAt" in r.repos[0]) fail("unused fields kept");
' "$tmp/page.js"

# Bad judgements and inventories are refused.
echo '{"picks": [], "verdicts": [{"ref": "me/app#1", "verdict": "delete-everything"}]}' >"$tmp/bad.json"
status=0
bash "$tmp/render" "$tmp/inventory.json" "$tmp/out.html" "$tmp/bad.json" 2>/dev/null || status=$?
[[ $status == 65 ]] || fail "an unknown verdict was accepted (exit $status)"
echo '{"threads": []}' >"$tmp/not-inventory.json"
status=0
bash "$tmp/render" "$tmp/not-inventory.json" "$tmp/out.html" 2>/dev/null || status=$?
[[ $status == 65 ]] || fail "a non-inventory file was accepted (exit $status)"
status=0
bash "$tmp/render" "$tmp/inventory.json" 2>/dev/null || status=$?
[[ $status == 64 ]] || fail "missing arguments did not exit 64 (exit $status)"

# A cut branch listing is named even when it produced no rows.
jq '.branches = [] | .branchesTruncated = ["gh:example-org/big"]' "$tmp/inventory.json" >"$tmp/cut.json"
bash "$tmp/render" "$tmp/cut.json" "$tmp/cut.html"
sed -n '/^<script>$/,/^<\/script>$/p' "$tmp/cut.html" | sed '1d;$d' >"$tmp/cut.js"
node -e '
  let html = "";
  global.document = {getElementById: () => ({insertAdjacentHTML: (_, h) => { html += h; }})};
  eval(require("fs").readFileSync(process.argv[1], "utf8"));
  if (!html.includes("Branches not fully read") || !html.includes("gh:example-org/big")) { console.error("FAIL: a cut listing without rows was not named"); process.exit(1); }
' "$tmp/cut.js"

# Without judgements the page still renders.
bash "$tmp/render" "$tmp/inventory.json" "$tmp/plain.html"
grep -qF '"picks":[]' "$tmp/plain.html" || fail "an empty pick list was not rendered"

# A scoped, thorough inventory: pulled-in items of the rows shown, the 15
# idlest leftover branches plus any judged, and checked verdicts.
branches=$(jq -cn '[range(18) | {ref: "me/app@b\(.)", forge: "forgejo", repo: "me/app", branch: "b\(.)", lane: "no-pr",
  idleDays: (40 + .), lastCommitAt: null, pr: null}]
  + [{ref: "gh:example-org/service@feat/x", forge: "github", repo: "example-org/service", branch: "feat/x",
      lane: "merged", idleDays: 1, head: ("a" * 40), ahead: 2, aheadOf: "main",
      pr: {ref: "gh:example-org/service#3", state: "merged", at: null, head: ("b" * 40)}}]
  + [{ref: "me/app@long", forge: "forgejo", repo: "me/app", branch: ("x" * 100), lane: "closed", idleDays: null,
      pr: {ref: "me/app#4", state: "closed", at: null}}]')
jq --argjson branches "$branches" '
  .scope = {kind: "selected", groups: ["work"], repos: [], missing: ["gh:example-org/missing"]}
  | .sources.branches = "ok"
  | .issues[0].related = ["gh:up/stream#4"] | .issues[0].flags = ["related-closed"]
  | .issues[2].related = ["other/lib#2"]
  | .issues[0].thread = {threadId: "t-1", title: "Thread naming the issue", bucket: "unsettled", status: "idle"}
  | .related = [
      {ref: "gh:up/stream#4", forge: "github", repo: "up/stream", number: 4, kind: "pr", state: "merged",
       title: "<img src=x onerror=alert(1)>", pulledBy: ["me/app#1", "me/app#3"]},
      {ref: "other/lib#2", forge: "forgejo", repo: "other/lib", number: 2, kind: "issue", state: "closed",
       title: "pulled by a hidden row", pulledBy: ["me/app#3"]}]
  | .branches = $branches | .totals.branches = ($branches | length) | .branchesTruncated = ["me/app"]
  | .totals.branchesRead = 31 | .totals.branchesSkipped = 11' "$tmp/inventory.json" >"$tmp/thorough.json"
cat >"$tmp/thorough-judgements.json" <<'JSON'
{"readerModel": "test", "focus": null, "picks": [],
 "verdicts": [{"ref": "me/app@long", "verdict": "keep", "reason": "still used"},
   {"ref": "gh:example-org/service@feat/x", "verdict": "delete", "reason": "Landed as #3", "checked": true},
   {"ref": "me/app#2", "verdict": "refresh", "reason": "Status is old", "checked": false}]}
JSON
bash "$tmp/render" "$tmp/thorough.json" "$tmp/thorough.html" "$tmp/thorough-judgements.json"
sed -n '/^<script>$/,/^<\/script>$/p' "$tmp/thorough.html" | sed '1d;$d' >"$tmp/thorough.js"
node -e '
  const fs = require("fs");
  const src = fs.readFileSync(process.argv[1], "utf8");
  const r = JSON.parse(src.split("/*REPORT-START*/")[1].split("/*REPORT-END*/")[0]);
  const fail = m => { console.error("FAIL: " + m); process.exit(1); };
  if (r.scope.groups[0] !== "work" || r.scope.missing[0] !== "gh:example-org/missing") fail("scope lost");
  if (r.related.length !== 1 || r.related[0].ref !== "gh:up/stream#4" || r.related[0].pulledBy.join() !== "me/app#1")
    fail("pulled-in items not limited to the rows shown: " + JSON.stringify(r.related));
  const issue = r.issues.find(i => i.ref === "me/app#1");
  if (issue.related[0] !== "gh:up/stream#4") fail("a row lost its related refs");
  const refs = r.branches.map(b => b.ref);
  if (r.branches.length !== 17 || r.branchesHidden !== 3 || refs[0] !== "me/app@b17" || !refs.includes("gh:example-org/service@feat/x")
      || !refs.includes("me/app@long"))
    fail("branches not capped at the 15 idlest plus judged: " + refs.join(" "));
  const judged = r.branches.find(b => b.ref === "gh:example-org/service@feat/x").judged;
  if (judged.verdict !== "delete" || judged.checked !== true) fail("a checked branch verdict was lost");
  if (r.issues.find(i => i.ref === "me/app#2").judged.checked !== undefined) fail("an unchecked verdict kept checked: false");
  // Run the page against a stub document: every section renders and untrusted text stays escaped.
  let html = "";
  global.document = {getElementById: () => ({insertAdjacentHTML: (_, h) => { html += h; }})};
  eval(src);
  for (const want of ["Leftover branches · 20", "Branches not fully read (more than 100, or more than 100 protected) in me/app", "/src/branch/" + "x".repeat(100) + "\"", "3 more not shown", "Pulled in from outside the scope · 1", "Scope: group work.",
                      "Not found or archived, so not read: gh:example-org/missing", "related: <a", "(merged)",
                      "https://github.com/example-org/service/tree/feat/x", "/me/app/src/branch/b17", ">checked<", ">delete<",
                      "merged, head differs from the branch\u0027s · 2 commits not in main", "11 of 31 read skipped",
                      "thread: Thread naming the issue"])
    if (!html.includes(want)) fail("page lacks " + want);
  if (html.includes("<img src=x")) fail("a pulled-in title was not escaped");
' "$tmp/thorough.js"
echo "backlog-overview-render contract tests passed"
