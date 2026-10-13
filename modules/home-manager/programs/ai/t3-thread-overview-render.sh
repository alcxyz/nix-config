# shellcheck shell=bash
# Render the T3 thread overview page from a report file (ADR-0091).
#
# Usage: t3-thread-overview-render REPORT.json OUT.html [STATUS.json]
#
# The Nix wrapper sets overview_template and t3-page.sh's function. Reader
# summaries and thread titles are untrusted text, so the report is never
# pasted into the page by hand: this checks its shape and writes the page with
# t3_page_write. STATUS.json is t3-thread-status output for the threads; each
# thread it covers gets its verdict, Settle: line, steps left for the user and
# stall reasons as `facts`.
: "${overview_template:?}"

if (($# != 2 && $# != 3)); then
  echo "usage: t3-thread-overview-render REPORT.json OUT.html [STATUS.json]" >&2
  exit 64
fi
report=$1
out=$2
status_file=${3:-}

facts='{}'
if [ -n "$status_file" ]; then
  if ! facts=$(jq -cs '
    if length == 1 and (.[0].threads | type) == "array"
      and all(.[0].threads[]; type == "object" and (.threadId | type) == "string"
        and (.verdict | . == null or type == "string") and (.stallReasons | type) == "array")
    then .[0].threads else error("expected t3-thread-status output") end
    | map({key: .threadId, value: {verdict, stallReasons,
        settle: (.settle | if . == null then null else {verdict, line, owner, stale, leftForYou} end)}})
    | from_entries' "$status_file"); then
    echo "t3-thread-overview-render: $status_file is not t3-thread-status output." >&2
    exit 65
  fi
fi

# One report, with the types the page relies on; anything else would leave a
# blank or half-rendered page.
if ! json=$(jq -cs --argjson facts "$facts" '
  def list: . == null or type == "array";
  if length == 1 and (.[0] | type == "object"
    and (.generatedAt | type) == "string"
    and (.threads | type) == "array"
    and all(.threads[]; type == "object" and (.threadId | type) == "string"
      and (.prs | list) and (.done | list) and (.remaining | list) and (.waitingOn | list)))
  then .[0] else error("expected one {generatedAt, threads: [{threadId, ...}]} report") end
  # The page is passed to the preview and render tools whole, so drop what it
  # never shows: inventory timestamps and PRs that are no longer open.
  | .threads |= map(del(.createdAt, .snoozedUntil)
    | .prs |= (if . == null then . else map(select(type == "object" and .state == "open")) end)
    | .facts = $facts[.threadId])
' "$report"); then
  echo "t3-thread-overview-render: $report is not a valid overview report." >&2
  exit 65
fi

t3_page_write t3-thread-overview-render "$overview_template" "$json" "$out"
