# shellcheck shell=bash
# Render the T3 thread overview pages from a report file (ADR-0091).
#
# Usage: t3-thread-overview-render REPORT.json OUTDIR [STATUS.json]
#
# The Nix wrapper sets overview_template and t3-page.sh's function. Reader
# summaries and thread titles are untrusted text, so the report is never
# pasted into a page by hand: this checks its shape and writes the pages with
# t3_page_write. STATUS.json is t3-thread-status output; each thread it covers
# gets its verdict, Settle: line and stall reasons as `facts`.
#
# Each section (waiting on you, stalled, ready to settle, recently settled,
# agent side) becomes its own page, so T3 shows each in its own frame. Only
# non-empty sections get a page; OUTDIR/pages.json lists them in order as
# {file, title, height}. Grouping happens here, so a page carries only its
# own threads.
: "${overview_template:?}"

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

# One report, with the types the pages rely on; anything else would leave a
# blank or half-rendered page.
if ! pages=$(jq -cs --argjson facts "$facts" '
  def list: . == null or type == "array";
  # Reader output is untrusted: progress is forced to a whole number in 0..100.
  def pct: (if type == "number" then . elif type == "string" then (tonumber? // null) else null end)
    | if . == null then null else [0, ., 100] | sort | .[1] | round end;
  # Like T3, only a background `command` (a server, or a wait outside a
  # Monitor) lets a thread count as done; every other kind wakes the agent
  # (#627). Settled threads lost their session, so their work is not shown.
  def pending: if .bucket == "recently-settled" then []
    else (.waitingOn // []) | map(select(type == "object" and (.kind | type) == "string")) end;
  def said: .facts.settle | if . != null and .stale != true then . else null end;
  # The owner a thread names in its own "not yet: ..., <owner>" beats the reader.
  def owner: (if said.verdict == "not-yet" and said.owner != null then said.owner else .owner end)
    | if . == "agent" then "agent" else "user" end;
  # A settled thread whose facts agree with its own Settle: ready line needs
  # no reader; one that left steps for the user stays in view until done.
  def facts_settled: .bucket == "recently-settled" and (.facts.verdict | IN("done", "left-for-you"));
  def group:
    if .bucket == "recently-settled" then
      if .acknowledged == true then "settled-done"
      elif facts_settled then (if .facts.verdict == "done" then "settled-done" else "settled-open" end)
      elif .verdict == "done" then "settled-done" else "settled-open" end
    else (.facts // {}) as $f
      | if (pending | any(.kind != "command")) or $f.verdict == "waiting" then "waiting"
        elif $f.verdict == "ready" then "settle"
        # A thread that only went quiet while the reader says it waits on you
        # stays there, with a stalled chip; anything it left behind moves it.
        elif $f.verdict == "stalled" then
          (if (($f.stallReasons // []) | all(tostring | startswith("idle"))) and owner == "user"
           then "user" else "stalled" end)
        elif $f.verdict == "not-yet" and said != null then owner
        elif .phase == "done-not-settled" then "settle"
        else owner end
    end;

  if length == 1 and (.[0] | type == "object"
    and (.generatedAt | type) == "string"
    and (.environmentId | . == null or type == "string")
    and (.threads | type) == "array"
    and all(.threads[]; type == "object" and (.threadId | type) == "string"
      and (.prs | list) and (.done | list) and (.remaining | list) and (.waitingOn | list)))
  then .[0] else error("expected one {generatedAt, threads: [{threadId, ...}]} report") end
  # Pages are passed to the render tool whole, so drop what they never show:
  # inventory timestamps and PRs that are no longer open.
  | .threads |= map(del(.createdAt, .snoozedUntil)
    | .prs |= (if . == null then . else map(select(type == "object" and .state == "open")) end)
    | .facts = $facts[.threadId]
    # Without reader output, the thread own Left for you: line is the next step.
    | if facts_settled and .phase == null then
        .facts.settle.leftForYou as $left
        | .phase = (if $left then "awaiting-user" else "done-not-settled" end)
        | .progressPct = 100 | .owner = "user" | .nextAction = $left
      else . end
    | .progressPct |= pct
    | .waitingOn = pending
    | .group = group
    | .owner = owner)
  | . as $r
  | ($r.threads | map(select(.bucket != "recently-settled"))) as $u
  | def count($g): [$r.threads[] | select(.group | IN($g[]))] | length;
    {unsettled: ($u | length),
     user: count(["user"]), agent: count(["agent", "waiting"]), stalled: count(["stalled"]),
     settle: count(["settle"]), settledOpen: count(["settled-open"]),
     avgPct: (if ($u | length) > 0 then ([$u[] | .progressPct // 0] | add / length | round) else null end),
     phases: ($u | map(.phase // "unknown") | group_by(.) | map({key: .[0], value: length}) | from_entries)} as $summary
  | [{key: "you", title: "Waiting on you", groups: ["user"]},
     {key: "stalled", title: "Stalled, no handoff", groups: ["stalled"]},
     {key: "settle", title: "Ready to settle", groups: ["settle"]},
     {key: "settled", title: "Settled in the last \($r.windowDays // "?") days", groups: ["settled-open", "settled-done"]},
     {key: "agent", title: "Agent side, no action from you", groups: ["agent", "waiting"]}]
  | map(. as $s | [$r.threads[] | select(.group | IN($s.groups[]))] as $ts
      | select($ts | length > 0)
      | {key, title: "\(.title) (\($ts | length))",
         report: ($r | .threads = $ts | .section = {key: $s.key, title: $s.title})})
  | if length == 0 then [{key: "summary", title: "No open threads", report: ($r | .section = {key: "summary", title: "T3 threads"})}] else . end
  # The first page carries the counts, the last the provenance note.
  | .[0].report.summary = $summary
  | .[-1].report.footer = true
' "$report"); then
  echo "t3-thread-overview-render: $report is not a valid overview report." >&2
  exit 65
fi

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
