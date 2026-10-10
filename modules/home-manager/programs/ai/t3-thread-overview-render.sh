# shellcheck shell=bash
# Render the T3 thread overview page from a report file (ADR-0091).
#
# Usage: t3-thread-overview-render REPORT.json OUT.html
#
# The Nix wrapper sets overview_template. Reader summaries and thread titles
# are untrusted text, so the report is never pasted into the page by hand:
# this checks its shape and writes every "<" as <, so no title can close
# the page's script element.
: "${overview_template:?}"

if (($# != 2)); then
  echo "usage: t3-thread-overview-render REPORT.json OUT.html" >&2
  exit 64
fi
report=$1
out=$2
start='/*REPORT-START*/'
end='/*REPORT-END*/'

# One report, with the types the page relies on; anything else would leave a
# blank or half-rendered page.
if ! json=$(jq -cs '
  def list: . == null or type == "array";
  if length == 1 and (.[0] | type == "object"
    and (.generatedAt | type) == "string"
    and (.threads | type) == "array"
    and all(.threads[]; type == "object" and (.threadId | type) == "string"
      and (.prs | list) and (.done | list) and (.remaining | list)))
  then .[0] else error("expected one {generatedAt, threads: [{threadId, ...}]} report") end
  # The page is passed to the preview and render tools whole, so drop what it
  # never shows: inventory timestamps and PRs that are no longer open.
  | .threads |= map(del(.createdAt, .snoozedUntil)
    | .prs |= (if . == null then . else map(select(type == "object" and .state == "open")) end))
' "$report"); then
  echo "t3-thread-overview-render: $report is not a valid overview report." >&2
  exit 65
fi
json=${json//</\\u003c}

template=$(<"$overview_template")
head=${template%%"$start"*}
rest=${template#*"$start"}
tail=${rest#*"$end"}
# Exactly one start marker, followed by exactly one end marker.
if [[ "$rest" == "$template" || "$head" == *"$end"* || "$rest" == *"$start"* ||
  "$tail" == "$rest" || "$tail" == *"$end"* ]]; then
  echo "t3-thread-overview-render: the template needs one $start ... $end block." >&2
  exit 70
fi
printf '%s%s\n%s\n%s%s\n' "$head" "$start" "$json" "$end" "$tail" >"$out"
