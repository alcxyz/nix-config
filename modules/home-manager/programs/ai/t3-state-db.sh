# shellcheck shell=bash
# Shared by t3-thread-inventory and t3-thread-status (ADR-0091): find the T3
# state database that holds a thread, query it read-only, and check that it
# still has the shape t3-thread-common.sql relies on.
#
# Callers set prog (for messages) and dbs (the databases to try), and may set
# sql_extra to more sqlite3 -cmd arguments.
# shellcheck disable=SC2154 # prog and dbs come from the caller

sql_extra=()

# The thread ID goes into a sqlite dot-command, so allow only the characters
# T3 uses in IDs.
t3_valid_id() {
  [[ $1 =~ ^[A-Za-z0-9:%._-]+$ ]]
}

# t3_sql DB THREAD [sqlite3 args...]: THREAD becomes :thread. The dot-command
# parser strips one level of quotes, so the value is double-quoted around a
# single-quoted SQL literal to stay text.
t3_sql() {
  local db=$1 thread=$2
  shift 2
  # T3 writes concurrently, so wait out its locks instead of failing.
  sqlite3 -readonly -bail "file:$db?mode=ro" \
    -cmd '.timeout 5000' \
    -cmd ".parameter set :thread \"'$thread'\"" \
    "${sql_extra[@]}" "$@"
}

# t3_select_db THREAD: print the first readable database that holds THREAD, or
# the first readable one when THREAD is empty. Exits 2 when none does, and 3
# when a database exists but cannot be queried.
t3_select_db() {
  local thread=$1 db found
  local unreadable=()
  for db in "${dbs[@]}"; do
    [ -r "$db" ] || continue
    if [ -z "$thread" ]; then
      printf '%s\n' "$db"
      return
    fi
    if ! found=$(t3_sql "$db" "$thread" "SELECT count(*) FROM orchestration_v2_projection_threads WHERE thread_id = :thread;"); then
      unreadable+=("$db")
      continue
    fi
    if [ "$found" = 1 ]; then
      printf '%s\n' "$db"
      return
    fi
  done
  # A database that exists but cannot be queried points at a schema change.
  if [ "${#unreadable[@]}" -gt 0 ]; then
    echo "$prog: could not query ${unreadable[*]}; T3's schema may have changed" >&2
    exit 3
  fi
  echo "$prog: no readable T3 state database${thread:+ holding thread $thread} among: ${dbs[*]}" >&2
  exit 2
}

# t3_count_drift DB WHAT SQL: fail with exit 3 unless the count SQL returns 0.
t3_count_drift() {
  local db=$1 what=$2 sql=$3 drift
  if ! drift=$(t3_sql "$db" "" "$sql"); then
    echo "$prog: schema check failed on $db" >&2
    exit 3
  fi
  if [ "$drift" != 0 ]; then
    echo "$prog: $drift $what in $db; T3's schema has changed" >&2
    exit 3
  fi
}

# t3_check_schema DB: every thread payload must carry the fields the views
# rely on; a missing key would otherwise make settled threads look unsettled,
# or waiting threads look done.
t3_check_schema() {
  t3_count_drift "$1" "threads lack settlement, lineage or provider fields" \
    "SELECT count(*) FROM orchestration_v2_projection_threads WHERE json_type(payload_json, '\$.settledOverride') IS NULL OR json_type(payload_json, '\$.settledAt') IS NULL OR json_type(payload_json, '\$.lineage') IS NULL OR json_type(payload_json, '\$.activeProviderThreadId') IS NULL;"
  t3_count_drift "$1" "provider threads lack a background task list" \
    "SELECT count(*) FROM orchestration_v2_projection_provider_threads WHERE CASE WHEN json_valid(payload_json) THEN coalesce(json_type(payload_json, '\$.pendingBackgroundTasks'), '') <> 'array' ELSE 1 END;"
}
