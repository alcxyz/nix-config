# shellcheck shell=bash
# Shared by the T3 page renderers (ADR-0091): put a JSON report into a fixed
# HTML template, between its /*REPORT-START*/ and /*REPORT-END*/ markers.

# t3_page_write PROG TEMPLATE JSON OUT: JSON is one compact document. Every "<"
# is written as <, so no text in it can close the page's script element.
t3_page_write() {
  local prog=$1 template_file=$2 json=$3 out=$4
  local start='/*REPORT-START*/' end='/*REPORT-END*/' template head rest tail
  json=${json//</\\u003c}
  template=$(<"$template_file")
  head=${template%%"$start"*}
  rest=${template#*"$start"}
  tail=${rest#*"$end"}
  # Exactly one start marker, followed by exactly one end marker.
  if [[ "$rest" == "$template" || "$head" == *"$end"* || "$rest" == *"$start"* ||
    "$tail" == "$rest" || "$tail" == *"$end"* ]]; then
    echo "$prog: the template needs one $start ... $end block." >&2
    exit 70
  fi
  printf '%s%s\n%s\n%s%s\n' "$head" "$start" "$json" "$end" "$tail" >"$out"
}
