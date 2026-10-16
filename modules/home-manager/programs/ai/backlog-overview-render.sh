# shellcheck shell=bash
# Render the backlog overview page from backlog-inventory output (ADR-0093).
#
# Usage: backlog-overview-render INVENTORY.json OUT.html [JUDGEMENTS.json]
#
# The Nix wrapper sets backlog_template and t3-page.sh's function. Titles and
# reader reasons are untrusted text, so nothing is pasted into the page by
# hand: this checks the shapes, keeps only the rows the page shows, and writes
# it with t3_page_write. JUDGEMENTS.json is the skill's own output:
#   {"readerModel": "...", "focus": "OWNER/REPO" or null,
#    "picks": [{"ref", "why"}], "verdicts": [{"ref", "verdict", "reason", "checked"}]}
# A verdict's ref may name an issue, a PR or a branch row (`OWNER/REPO@BRANCH`);
# `checked` marks verdicts the thorough mode's checking pass confirmed.
: "${backlog_template:?}"

if (($# != 2 && $# != 3)); then
  echo "usage: backlog-overview-render INVENTORY.json OUT.html [JUDGEMENTS.json]" >&2
  exit 64
fi
inventory=$1
out=$2
judgements_file=${3:-}

judgements='{"readerModel":null,"focus":null,"picks":[],"verdicts":[]}'
if [ -n "$judgements_file" ]; then
  if ! judgements=$(jq -cs '
    def str: type == "string";
    def opt: . == null or type == "string";
    if length == 1 and (.[0] | type == "object"
      and (.readerModel | opt) and (.focus | opt)
      and (.picks // [] | type == "array" and all(.[]; type == "object" and (.ref | str) and (.why | opt)))
      and (.verdicts // [] | type == "array" and all(.[]; type == "object" and (.ref | str)
        and (.verdict | IN("close", "dispatch", "refresh", "keep", "drop", "unclear", "delete")) and (.reason | opt)
        and (.checked | . == null or type == "boolean"))))
    then .[0] | {readerModel, focus, picks: (.picks // []), verdicts: (.verdicts // [])}
    else error("expected {readerModel, focus, picks, verdicts}") end' "$judgements_file"); then
    echo "backlog-overview-render: $judgements_file is not a judgements file." >&2
    exit 65
  fi
fi

# The agent passes the page to the preview and render tools inline, so it
# stays small: the 12 repositories with most decisions waiting, at most five
# PRs per lane (plus any judged or picked), the issues that ask for a decision (maybe done, blocked,
# judged or picked), the focus repository's issues, the eight idlest stale
# issues, the 15 idlest leftover branches (plus any judged) and the first 15
# pulled-in items of the rows shown, with long text cut. Every cut is counted
# on the page. Inventories from before scopes (no related or branches) still render.
if ! json=$(jq -cs --argjson j "$judgements" '
  def list: type == "array";
  if length == 1 and (.[0] | type == "object"
    and (.generatedAt | type) == "string"
    and (.repos | list) and (.issues | list) and (.prs | list)
    and all(.issues[], .prs[]; type == "object" and (.ref | type) == "string"
      and (.lane | type) == "string" and (.flags | list))
    and (.related // [] | list and all(.[]; type == "object" and (.ref | type) == "string" and (.pulledBy | list)))
    and (.branches // [] | list and all(.[]; type == "object" and (.ref | type) == "string" and (.lane | type) == "string")))
  then .[0] else error("expected backlog-inventory output") end
  | . as $inv
  | ($j.verdicts | map({key: .ref, value: {verdict, reason, checked}}) | from_entries) as $verdicts
  | ($j.picks | map(.ref)) as $picked
  | def keep_issue: .lane == "close"
      or (.flags | any(. == "untouched-since-merge" or . == "blocked" or . == "validation-needed"))
      or $verdicts[.ref] != null or (.ref | IN($picked[])) or ($j.focus != null and .repo == $j.focus);
    def cut($n): if type == "string" and length > $n then .[:$n - 1] + "…" else . end;
    def keep_pr: $verdicts[.ref] != null or (.ref | IN($picked[]));
    def compact: with_entries(select(.value != null and .value != [] and .value != {} and .value != false));
    def judged: $verdicts[.ref] | if . == null then null else (.reason |= cut(120)) | compact end;
    def slim: {ref, title: (.title | cut(90)), lane, flags: (.flags - ["mentioned-by-merged-pr"]), idleDays, checks,
      next: (.status.next | cut(120)), openPrs,
      mergedPrs: [.mergedPrs | sort_by(.mergedAt) | reverse | .[:3][].ref], mergedCount: (.mergedPrs | length | if . > 3 then . else null end),
      related: (.related // [])[:3], judged: judged} | compact;
    def slim_pr: {ref, title: (.title | cut(90)), lane, flags, kind, author: (if .kind == "bot" then .author else null end), ci, idleDays,
      issues, thread: (.thread | if . == null then null else {threadId, title: (.title | cut(60)), bucket} end),
      related: (.related // [])[:3], judged: judged} | compact;
    def slim_branch: {ref, forge, repo, branch, lane, idleDays,
      pr: (.pr | if . == null then null else {ref, state} end), judged: judged} | compact;
    ([.prs | group_by(.lane)[] | sort_by(-.idleDays)]) as $lanes
  | ([.issues[] | select(.lane == "stale" and (keep_issue | not))] | sort_by(-.idleDays)) as $stale
  | ([$lanes[] | .[:5] + [.[5:][] | select(keep_pr)] | .[] | slim_pr]) as $prs
  | ([.issues[] | select(keep_issue)] + $stale[:8] | map(slim)) as $issues
  | ([$prs[].ref, $issues[].ref]) as $shown
  | ([.related // [] | .[] | select(any(.pulledBy[]; IN($shown[])))]) as $related
  | ([.branches // [] | .[]] | sort_by(-(.idleDays // 0))) as $branches
  | {generatedAt, staleDays, sources, totals,
     scope: (.scope // null | if . == null then null else {kind, groups, repos, missing} end),
     repos: [.repos[:12][] | {forge, repo, openIssues, openPrs, actionable, issues, prs, branches, lastActivity} | compact],
     reposHidden: ([.repos[12:][]] | length),
     readerModel: $j.readerModel, focus: $j.focus,
     picks: [$j.picks[] | . as $p | {ref, why, title: ([$inv.issues[], $inv.prs[]] | map(select(.ref == $p.ref)) | first | .title?),
       pr: any($inv.prs[]; .ref == $p.ref)}],
     prs: $prs,
     prsHidden: ([$lanes[] | [.[5:][] | select(keep_pr | not)] | select(length > 0)
       | {key: .[0].lane, value: length}] | from_entries),
     issues: $issues,
     staleHidden: ([$stale[8:][]] | length),
     related: [$related[:15][] | {ref, kind, state, title: (.title | cut(90)), pulledBy: (.pulledBy | map(select(IN($shown[]))) | .[:3])} | compact],
     relatedHidden: ([$related[15:][]] | length),
     branches: ($branches[:15] + [$branches[15:][] | select($verdicts[.ref] != null)] | map(slim_branch)),
     branchesHidden: ([$branches[15:][] | select($verdicts[.ref] == null)] | length),
     branchesTruncated: (.branchesTruncated // [])}
' "$inventory"); then
  echo "backlog-overview-render: $inventory is not backlog-inventory output." >&2
  exit 65
fi

t3_page_write backlog-overview-render "$backlog_template" "$json" "$out"
