# shellcheck shell=bash
# List unsettled and recently settled top-level T3 threads as JSON (ADR-0091).
#
# --thread names the calling thread: it selects the state database that holds
# it (one per T3 instance) and is left out of the output.

# The Nix wrapper sets these, and t3-state-db.sh's functions, before this text.
: "${common_sql:?}" "${inventory_sql:?}" "${default_dbs:?}"
prog=t3-thread-inventory
days=3
thread=""
dbs=()

usage() {
  cat >&2 <<'USAGE'
Usage: t3-thread-inventory [--days N] [--thread ID] [--db PATH]...
  --days N     also list threads settled within N days (default 3)
  --thread ID  the calling thread: picks its T3 instance and is left out
  --db PATH    state database to try (repeatable; default: every T3 instance)
Exit codes: 2 no database found, 3 schema check or query failed (fall back to
T3's MCP tools), 64 usage.
USAGE
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --days | --thread | --db)
      if [ "$#" -lt 2 ]; then
        usage
        exit 64
      fi
      case $1 in
        --days) days=$2 ;;
        --thread) thread=$2 ;;
        --db) dbs+=("$2") ;;
      esac
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

if ! [[ $days =~ ^[0-9]{1,3}$ ]]; then
  echo "$prog: --days must be a whole number of days" >&2
  exit 64
fi
if [ -n "$thread" ] && ! t3_valid_id "$thread"; then
  echo "$prog: unexpected characters in --thread" >&2
  exit 64
fi
if [ "${#dbs[@]}" -eq 0 ]; then
  IFS=: read -r -a dbs <<<"${T3_STATE_DBS:-$default_dbs}"
fi
# shellcheck disable=SC2034 # read by t3_sql
sql_extra=(-cmd ".parameter set :days $days")

selected=$(t3_select_db "$thread")
t3_check_schema "$selected"

if ! rows=$(cat "$common_sql" "$inventory_sql" | t3_sql "$selected" "$thread" -json); then
  echo "$prog: query failed on $selected" >&2
  exit 3
fi
# Settled threads the user accepted as done (t3-thread-overview-ack) are
# marked while their settle time still matches. A broken file only loses the
# marks, so it warns instead of sending the overview to its MCP fallback.
ack_file=${T3_OVERVIEW_ACK_FILE:-${ack_file_default:-}}
acks='{}'
if [ -n "$ack_file" ] && [ -s "$ack_file" ] &&
  ! acks=$(jq -cse 'if length == 1 and (.[0] | type == "object") then .[0] else error("bad") end' "$ack_file" 2>/dev/null); then
  echo "$prog: ignoring $ack_file, which is not an acknowledgement file" >&2
  acks='{}'
fi
jq --arg db "$selected" --argjson days "$days" --argjson acks "$acks" \
  '{database: $db, windowDays: $days, threads: map(.prs |= fromjson | .waitingOn |= fromjson
    | if .bucket == "recently-settled" and .settledAt != null and $acks[.threadId] == .settledAt
      then .acknowledged = true else . end)}' <<<"${rows:-[]}"
