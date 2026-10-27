# Group the threads of one overview report into its sections (ADR-0091).
#
# Shared by t3-thread-overview-render, which writes a page per section, and
# t3-thread-overview-group, which prints the result for the deck dashboard,
# so both apply the same rules. Run with `jq -s --argjson facts FACTS`, where
# FACTS maps a thread ID to its t3-thread-status verdict, stall reasons and
# Settle: line. Prints {report, summary, sections: [{key, title, threads}]}:
# report is the input without its threads, and only non-empty sections are
# listed, in page order.

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
# Drop what no page shows: inventory timestamps and PRs that are no longer
# open.
| .threads |= map(del(.createdAt, .snoozedUntil)
  | .prs |= (if . == null then . else map(select(type == "object" and .state == "open")) end)
  | .facts = $facts[.threadId]
  # Without reader output, the thread own Left for you: line is the next step.
  | if facts_settled and .phase == null then
      .facts.settle.leftForYou as $left
      | .phase = (if $left then "awaiting-user" else "done-not-settled" end)
      | .progressPct = 100 | .owner = "user" | .nextAction = $left
    else . end
  # A thread that stopped while a linked PR's checks still run, with nothing
  # to wake it, looks idle although its work is not done: flag it only.
  | .unwatchedChecks = (if .bucket == "recently-settled" or (pending | any(.kind != "command"))
      or (.status | IN("queued", "preparing", "starting", "running")) then []
      else (.pendingUnwatched | if type == "array" then map(select(type == "string")) else [] end) end)
  | del(.pendingUnwatched)
  | .progressPct |= pct
  | .waitingOn = pending
  | .group = group
  | .owner = owner)
| . as $r
| ($r.threads | map(select(.bucket != "recently-settled"))) as $u
| def count($g): [$r.threads[] | select(.group | IN($g[]))] | length;
  {report: ($r | del(.threads)),
   summary: {unsettled: ($u | length),
     user: count(["user"]), agent: count(["agent", "waiting"]), stalled: count(["stalled"]),
     settle: count(["settle"]), settledOpen: count(["settled-open"]),
     unwatchedChecks: ([$u[] | select(.unwatchedChecks | length > 0)] | length),
     avgPct: (if ($u | length) > 0 then ([$u[] | .progressPct // 0] | add / length | round) else null end),
     phases: ($u | map(.phase // "unknown") | group_by(.) | map({key: .[0], value: length}) | from_entries)},
   sections: ([{key: "you", title: "Waiting on you", groups: ["user"]},
     {key: "stalled", title: "Stalled, no handoff", groups: ["stalled"]},
     {key: "settle", title: "Ready to settle", groups: ["settle"]},
     {key: "settled", title: "Settled in the last \($r.windowDays // "?") days", groups: ["settled-open", "settled-done"]},
     {key: "agent", title: "Agent side, no action from you", groups: ["agent", "waiting"]}]
     | map(. as $s | {key, title, threads: [$r.threads[] | select(.group | IN($s.groups[]))]}
       | select(.threads | length > 0)))}
