# shellcheck shell=bash
# Print a thread's first and latest messages as JSON (ADR-0091), for the deck
# dashboard's summaries (#757).
#
# Prints {threadId, messageCount, revision, lastActivityAt, latest: {id, at}
# | null, messages: [{position, role, kind, at, text}]}: the first --head and
# last --tail finished user and assistant messages, in order, each cut to
# --max-chars characters with a trailing "…". `latest` is the newest message
# by creation time. `revision` changes whenever any message finishes or
# changes, so a summary that stores it can tell when it is out of date, and
# `lastActivityAt` is when that last happened.

# The Nix wrapper sets these, and t3-state-db.sh's functions, before this text.
: "${messages_sql:?}" "${default_dbs:?}"
prog=t3-thread-messages
head=3
tail=30
max_chars=500
thread=""
dbs=()

usage() {
  cat >&2 <<'USAGE'
Usage: t3-thread-messages [--head N] [--tail N] [--max-chars N] [--db PATH]... THREAD_ID
  --head N       the first N messages (default 3)
  --tail N       the last N messages (default 30)
  --max-chars N  cut each message to N characters (default 500)
  --db PATH      state database to try (repeatable; default: every T3 instance)
Exit codes: 2 no database or thread found, 3 schema check or query failed,
64 usage.
USAGE
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --head | --tail | --max-chars | --db)
      if [ "$#" -lt 2 ]; then
        usage
        exit 64
      fi
      case $1 in
        --head) head=$2 ;;
        --tail) tail=$2 ;;
        --max-chars) max_chars=$2 ;;
        --db) dbs+=("$2") ;;
      esac
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage
      exit 64
      ;;
    *)
      if [ -n "$thread" ]; then
        usage
        exit 64
      fi
      thread=$1
      shift
      ;;
  esac
done

if [ -z "$thread" ]; then
  usage
  exit 64
fi
if ! t3_valid_id "$thread"; then
  echo "$prog: unexpected characters in the thread ID" >&2
  exit 64
fi
for n in "$head" "$tail" "$max_chars"; do
  if ! [[ $n =~ ^[0-9]{1,6}$ ]]; then
    echo "$prog: --head, --tail and --max-chars take whole numbers" >&2
    exit 64
  fi
done
if [ "${#dbs[@]}" -eq 0 ]; then
  IFS=: read -r -a dbs <<<"${T3_STATE_DBS:-$default_dbs}"
fi
# shellcheck disable=SC2034 # read by t3_sql
sql_extra=(-cmd ".parameter set :head $head" -cmd ".parameter set :tail $tail"
  -cmd ".parameter set :maxchars $max_chars")

selected=$(t3_select_db "$thread")
t3_check_schema "$selected"
# Every finished message of the thread must carry its text, or its summary
# would read an empty thread.
if ! drift=$(t3_sql "$selected" "$thread" "SELECT count(*) FROM orchestration_v2_projection_messages WHERE thread_id = :thread AND role IN ('user', 'assistant') AND NOT streaming AND coalesce(json_type(payload_json, '\$.text'), '') <> 'text';"); then
  echo "$prog: schema check failed on $selected" >&2
  exit 3
fi
if [ "$drift" != 0 ]; then
  echo "$prog: $drift messages lack their text in $selected; T3's schema has changed" >&2
  exit 3
fi

if ! out=$(t3_sql "$selected" "$thread" <"$messages_sql"); then
  echo "$prog: query failed on $selected" >&2
  exit 3
fi
printf '%s\n' "$out"
