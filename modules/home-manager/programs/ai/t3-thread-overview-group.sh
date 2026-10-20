# shellcheck shell=bash
# Group an overview report's threads into its sections and print them as JSON
# (ADR-0091), for the deck dashboard (#757).
#
# Usage: t3-thread-overview-group REPORT.json [STATUS.json]
#
# The rules are t3-thread-overview-group.jq, the ones t3-thread-overview-render
# uses for its pages. Prints the report without its threads, plus `summary`
# (the counts) and `sections`: [{key, title, threads}], non-empty sections
# only, in page order. Each thread gains `group`, its final `owner` and the
# `facts` STATUS.json (t3-thread-status output) gives it.
# The Nix wrapper sets overview_group_jq and t3-thread-overview-lib.sh's
# functions.
: "${overview_group_jq:?}"
prog=t3-thread-overview-group

if (($# != 1 && $# != 2)); then
  echo "usage: $prog REPORT.json [STATUS.json]" >&2
  exit 64
fi

facts='{}'
if (($# == 2)); then
  facts=$(t3_overview_facts "$prog" "$2") || exit 65
fi
grouped=$(t3_overview_group "$prog" "$1" "$facts") || exit 65
jq -c '.report + {summary, sections}' <<<"$grouped"
