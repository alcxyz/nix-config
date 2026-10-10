# shellcheck shell=bash
# List unsettled and recently settled top-level T3 threads as JSON (ADR-0091).
#
# --thread names the calling thread: it selects the state database that holds
# it (one per T3 instance) and is left out of the output.

# The Nix wrapper sets both before this text.
: "${inventory_sql:?}" "${default_dbs:?}"
days=3
thread=""
dbs=()

usage() {
  cat >&2 <<'EOF'
Usage: t3-thread-inventory [--days N] [--thread ID] [--db PATH]...
  --days N     also list threads settled within N days (default 3)
  --thread ID  the calling thread: picks its T3 instance and is left out
  --db PATH    state database to try (repeatable; default: every T3 instance)
Exit codes: 2 no database found, 3 schema check or query failed (fall back to
T3's MCP tools), 64 usage.
EOF
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
  echo "t3-thread-inventory: --days must be a whole number of days" >&2
  exit 64
fi
# The thread ID goes into a sqlite dot-command, so allow only the characters
# T3 uses in IDs. The dot-command parser strips one level of quotes, so the
# value is double-quoted around a single-quoted SQL literal to stay text.
if [ -n "$thread" ] && ! [[ $thread =~ ^[A-Za-z0-9:%._-]+$ ]]; then
  echo "t3-thread-inventory: unexpected characters in --thread" >&2
  exit 64
fi
if [ "${#dbs[@]}" -eq 0 ]; then
  IFS=: read -r -a dbs <<<"${T3_STATE_DBS:-$default_dbs}"
fi

run_sql() {
  local db=$1
  shift
  # T3 writes concurrently, so wait out its locks instead of failing.
  sqlite3 -readonly -bail "file:$db?mode=ro" \
    -cmd '.timeout 5000' \
    -cmd ".parameter set :days $days" \
    -cmd ".parameter set :exclude \"'$thread'\"" "$@"
}

selected=""
unreadable=()
for db in "${dbs[@]}"; do
  [ -r "$db" ] || continue
  if [ -z "$thread" ]; then
    selected=$db
    break
  fi
  if ! found=$(run_sql "$db" "SELECT count(*) FROM orchestration_v2_projection_threads WHERE thread_id = :exclude;"); then
    unreadable+=("$db")
    continue
  fi
  if [ "$found" = 1 ]; then
    selected=$db
    break
  fi
done
if [ -z "$selected" ]; then
  # A database that exists but cannot be queried points at a schema change.
  if [ "${#unreadable[@]}" -gt 0 ]; then
    echo "t3-thread-inventory: could not query ${unreadable[*]}; T3's schema may have changed" >&2
    exit 3
  fi
  echo "t3-thread-inventory: no readable T3 state database${thread:+ holding thread $thread} among: ${dbs[*]}" >&2
  exit 2
fi

# Every thread payload must carry the fields the query relies on; a missing
# key would otherwise make settled threads look unsettled.
if ! drift=$(run_sql "$selected" "SELECT count(*) FROM orchestration_v2_projection_threads WHERE json_type(payload_json, '\$.settledOverride') IS NULL OR json_type(payload_json, '\$.settledAt') IS NULL OR json_type(payload_json, '\$.lineage') IS NULL;"); then
  echo "t3-thread-inventory: schema check failed on $selected" >&2
  exit 3
fi
if [ "$drift" != 0 ]; then
  echo "t3-thread-inventory: $drift threads in $selected lack settlement or lineage fields; T3's schema has changed" >&2
  exit 3
fi

if ! rows=$(run_sql "$selected" -json <"$inventory_sql"); then
  echo "t3-thread-inventory: query failed on $selected" >&2
  exit 3
fi
jq --arg db "$selected" --argjson days "$days" \
  '{database: $db, windowDays: $days, threads: map(.prs |= fromjson)}' <<<"${rows:-[]}"
