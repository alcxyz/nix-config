# shellcheck shell=bash
# Render a T3 thread time breakdown page (ADR-0091, #676).
#
# Usage: t3-thread-time-render TIME.json [NOTES.json] OUT.html
#
# TIME.json is t3-thread-time output for one thread. NOTES.json, when given,
# holds the interpreting agent's reading:
#   {"summary": "...", "hotspots": [{"title": "...", "detail": "..."}],
#    "suggestions": ["..."], "requests": [{"number": 3, "note": "..."}]}
# Every field is optional. The Nix wrapper sets time_template and
# t3-page.sh's function; thread text reaches the page only through
# t3_page_write.
: "${time_template:?}"

if (($# == 2)); then
  time_file=$1
  notes_file=
  out=$2
elif (($# == 3)); then
  time_file=$1
  notes_file=$2
  out=$3
else
  echo "usage: t3-thread-time-render TIME.json [NOTES.json] OUT.html" >&2
  exit 64
fi

notes_args=(--argjson notes '[{}]')
if [[ -n "$notes_file" ]]; then
  notes_args=(--slurpfile notes "$notes_file")
fi

if ! json=$(jq -cn --slurpfile time "$time_file" "${notes_args[@]}" '
  def text: . == null or type == "string";
  def num: type == "number";
  def list(f): . == null or (type == "array" and all(.[]; f));
  if ($time | length) == 1 and ($time[0] | type == "object"
      and (.threadId | type) == "string" and (.activeSeconds | num)
      and (.categories | type == "array" and all(.[]; type == "object" and (.category | type) == "string" and (.seconds | num)))
      and (.timeline | type) == "array"
      and (.requests | list(type == "object" and (.number | num) and (.activeSeconds | num))))
  then $time[0] else error("expected t3-thread-time output for one thread") end
  | . as $t
  | if ($notes | length) == 1 and ($notes[0] | type == "object"
      and (.summary | text)
      and (.hotspots | list(type == "object" and (.title | type) == "string" and (.detail | type) == "string"))
      and (.suggestions | list(type == "string"))
      and (.requests | list(type == "object" and (.number | num) and (.note | type) == "string")))
    then $notes[0] else error("expected one notes object") end
  | . as $n
  # Only what the page shows: no database path.
  | $t | {generatedAt, idleMinutes, threadId, title, start, end, spanSeconds, activeSeconds,
      agentSeconds, waitSeconds, userSeconds, idleSeconds, categories, churn, reviewRuns, repeated,
      longest, binMinutes, timeline, requests: (.requests // []),
      notes: ($n | if . == {} then null
        else {summary, hotspots: (.hotspots // []), suggestions: (.suggestions // []), requests: (.requests // [])} end)}
'); then
  echo "t3-thread-time-render: $time_file${notes_file:+ or $notes_file} is not valid t3-thread-time output and notes." >&2
  exit 65
fi

t3_page_write t3-thread-time-render "$time_template" "$json" "$out"
