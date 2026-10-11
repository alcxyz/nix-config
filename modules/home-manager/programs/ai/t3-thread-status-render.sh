# shellcheck shell=bash
# Render a T3 thread status card (ADR-0091).
#
# Usage: t3-thread-status-render STATUS.json NOTES.json OUT.html
#
# STATUS.json is t3-thread-status output for one thread. NOTES.json holds what
# the facts cannot show, written by the reporting agent:
#   {"verdict": "ready|not-yet|waiting|stalled", "summary": "...",
#    "remaining": ["..."], "owner": "user|agent", "leftForYou": ["..."]}
# Every field is optional, except verdict for a --self report. The Nix wrapper
# sets status_card and t3-page.sh's function; thread text reaches the page
# only through t3_page_write.
: "${status_card:?}"

if (($# != 3)); then
  echo "usage: t3-thread-status-render STATUS.json NOTES.json OUT.html" >&2
  exit 64
fi
status_file=$1
notes_file=$2
out=$3

if ! json=$(jq -cn --slurpfile status "$status_file" --slurpfile notes "$notes_file" '
  def text: . == null or type == "string";
  def texts: . == null or (type == "array" and all(.[]; type == "string"));
  if ($status | length) == 1 and ($status[0].threads | type) == "array" and ($status[0].threads | length) == 1
    and ($status[0].threads[0] | type == "object" and (.threadId | type) == "string" and (.checks | type) == "array")
  then $status[0] else error("expected t3-thread-status output for one thread") end
  | . as $s
  | if ($notes | length) == 1 and ($notes[0] | type) == "object"
      and ($notes[0] | (.summary | text) and (.remaining | texts) and (.leftForYou | texts)
        and (.owner | . == null or . == "user" or . == "agent"))
    then $notes[0] else error("expected one notes object") end
  | . as $n
  | ($n.verdict // $s.threads[0].verdict) as $verdict
  | if ($verdict | IN("ready", "not-yet", "waiting", "stalled")) then . else error("no valid verdict") end
  | {generatedAt: $s.generatedAt, verdict: $verdict, summary: $n.summary,
     remaining: ($n.remaining // []), owner: $n.owner, leftForYou: ($n.leftForYou // []),
     # Only what the card shows.
     thread: ($s.threads[0] | {threadId, project, title, state, run: (.run | {status, active}),
       idleMinutes, self, settle, stallReasons,
       worktree: (.worktree | if . == null then null else {branch, head, exists} end),
       prs: [.prs[]? | {url, number, state, watched}],
       checks: [.checks[] | {label, pass, detail}]})}
'); then
  echo "t3-thread-status-render: $status_file or $notes_file is not valid status output and notes." >&2
  exit 65
fi

t3_page_write t3-thread-status-render "$status_card" "$json" "$out"
