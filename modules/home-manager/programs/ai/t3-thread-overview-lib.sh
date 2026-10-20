# shellcheck shell=bash
# Shared by t3-thread-overview-render and t3-thread-overview-group (ADR-0091):
# read t3-thread-status output into per-thread facts, and group a report's
# threads with t3-thread-overview-group.jq. The Nix wrapper sets
# overview_group_jq to that program's path.

# t3_overview_facts PROG STATUS: print {threadId: {verdict, stallReasons,
# settle}} from t3-thread-status output, or exit 65 when it is not that.
t3_overview_facts() {
  local prog=$1 status_file=$2
  if ! jq -cs '
    if length == 1 and (.[0].threads | type) == "array"
      and all(.[0].threads[]; type == "object" and (.threadId | type) == "string"
        and (.verdict | . == null or type == "string") and (.stallReasons | type) == "array")
    then .[0].threads else error("expected t3-thread-status output") end
    | map({key: .threadId, value: {verdict, stallReasons,
        settle: (.settle | if . == null then null else {verdict, line, owner, stale, leftForYou} end)}})
    | from_entries' "$status_file"; then
    echo "$prog: $status_file is not t3-thread-status output." >&2
    exit 65
  fi
}

# t3_overview_group PROG REPORT FACTS: print {report, summary, sections} for
# one overview report, or exit 65 when the report has the wrong shape.
t3_overview_group() {
  local prog=$1 report=$2 facts=$3
  : "${overview_group_jq:?}"
  if ! jq -cs --argjson facts "$facts" -f "$overview_group_jq" "$report"; then
    echo "$prog: $report is not a valid overview report." >&2
    exit 65
  fi
}
