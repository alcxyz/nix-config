# shellcheck shell=bash
# Render the T3 thread overview pages from a report file (ADR-0091).
#
# Usage: t3-thread-overview-render REPORT.json OUTDIR [STATUS.json]
#
# The Nix wrapper sets overview_template, overview_group_jq and the functions
# of t3-page.sh and t3-thread-overview-lib.sh. Reader summaries and thread
# titles are untrusted text, so the report is never pasted into a page by
# hand: this checks its shape and writes the pages with t3_page_write. STATUS.json is t3-thread-status output; each thread it covers
# gets its verdict, Settle: line and stall reasons as `facts`.
#
# Each section (waiting on you, stalled, ready to settle, recently settled,
# agent side) becomes its own page, so T3 shows each in its own frame. Only
# non-empty sections get a page; OUTDIR/pages.json lists them in order as
# {file, title, height}. Grouping happens here, with the rules in
# t3-thread-overview-group.jq, so a page carries only its own threads.
: "${overview_template:?}" "${overview_group_jq:?}"

if (($# != 2 && $# != 3)); then
  echo "usage: t3-thread-overview-render REPORT.json OUTDIR [STATUS.json]" >&2
  exit 64
fi
report=$1
out_dir=$2
status_file=${3:-}
if [ -e "$out_dir" ] && [ ! -d "$out_dir" ]; then
  echo "t3-thread-overview-render: $out_dir is not a directory." >&2
  exit 64
fi

facts='{}'
if [ -n "$status_file" ]; then
  facts=$(t3_overview_facts t3-thread-overview-render "$status_file") || exit 65
fi

# One page per non-empty section, or a summary page when there is none. The
# first page carries the counts, the last the provenance note.
grouped=$(t3_overview_group t3-thread-overview-render "$report" "$facts") || exit 65
pages=$(jq -c '
  . as $g
  | $g.sections
  | map({key, title: "\(.title) (\(.threads | length))",
      report: ($g.report + {threads, section: {key, title}})})
  | if length == 0 then [{key: "summary", title: "No open threads",
      report: ($g.report + {threads: [], section: {key: "summary", title: "T3 threads"}})}] else . end
  | .[0].report.summary = $g.summary
  | .[-1].report.footer = true' <<<"$grouped")

mkdir -p -- "$out_dir"
out_dir=$(cd -- "$out_dir" && pwd)
count=$(jq length <<<"$pages")
for ((i = 0; i < count; i++)); do
  key=$(jq -r ".[$i].key" <<<"$pages")
  t3_page_write t3-thread-overview-render "$overview_template" \
    "$(jq -c ".[$i].report" <<<"$pages")" "$out_dir/$((i + 1))-$key.html"
done
# A frame shrinks to its page, so the height only caps long sections, which
# then scroll inside their own frame.
jq --arg dir "$out_dir" 'to_entries | map({file: "\($dir)/\(.key + 1)-\(.value.key).html",
  title: "T3 threads: \(.value.title)", height: 640})' <<<"$pages" >"$out_dir/pages.json"
