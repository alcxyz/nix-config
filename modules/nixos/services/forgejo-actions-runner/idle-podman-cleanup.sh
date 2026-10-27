#!/usr/bin/env bash
set -euo pipefail

state_dir=${STATE_DIR:-/run/forgejo-runner-aggregate-pressure}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
curl_bin=${CURL_BIN:-curl}
df_bin=${DF_BIN:-df}
jq_bin=${JQ_BIN:-jq}
docker_socket=${DOCKER_SOCKET:-/run/forgejo-docker/docker.sock}
podman_socket=${PODMAN_SOCKET:-/run/forgejo-podman/podman.sock}
disk_path=${DISK_PATH:-/}
# Usage of the filesystem holding the Podman store triggers the cleanup and
# measures what it reclaimed; DISK_PATH stays the guard's critical floor.
store_path=${STORE_PATH:-/var/lib/forgejo-podman/storage}
trigger_used_percent=${TRIGGER_USED_PERCENT:-70}
pressure_only=${PRESSURE_ONLY:-1}
critical_free_bytes=${CRITICAL_FREE_BYTES:-0}
critical_free_percent=${CRITICAL_FREE_PERCENT:-0}
image_min_age=${IMAGE_MIN_AGE:-48h}
# Runner jobs and their shutdown each time out after an hour, so a live
# container older than this cannot belong to a job.
stale_after_seconds=${STALE_AFTER_SECONDS:-10800}
# Runner start gates wait up to 60 s for the lifecycle lock, so API work under
# the lock stops starting new steps after this many seconds.
lock_budget_seconds=${LOCK_BUDGET_SECONDS:-40}
# A pass may make partial progress; never turn selection into a bulk prune.
image_limit=${IMAGE_DELETE_LIMIT:-8}
container_limit=${CONTAINER_DELETE_LIMIT:-8}
docker_volume_manifest=${DOCKER_VOLUME_MANIFEST:-}
fence=$state_dir/cleanup-in-flight
umask 077
primary_runner=forgejo-actions-runner.service
podman_runner=forgejo-podman-runner.service
# The primary Docker runner, then every Podman runner in the guard's order.
runner_units_text=${RUNNER_UNITS:-}
# Buildx docker-container builders run as buildx_buildkit_<node> and keep their
# BuildKit state in buildx_buildkit_<node>_state.
builder_pattern='^buildx_buildkit_[A-Za-z0-9][A-Za-z0-9_.-]*$'
builder_volume_pattern='^buildx_buildkit_[A-Za-z0-9][A-Za-z0-9_.-]*_state$'
# Podman serves its native API only under a version prefix.
libpod=/v5.0.0/libpod

# Every skipped run logs its first failed guard. Uncertain mutations fail
# immediately and retain the fence rather than attempting later work.
skip() {
  printf 'skipped reason=%s\n' "$*"
  exit 0
}
fail() {
  printf 'failed step=%s\n' "$*" >&2
  exit 1
}

# A retained completion fence is a failure even outside a cleanup window.
# Check again under the lock to exclude a concurrent cleanup creating one.
[[ ! -e $fence && ! -L $fence ]] || fail cleanup_in_flight

[[ $trigger_used_percent =~ ^[1-9][0-9]?$ ]] || exit 1
[[ $pressure_only == 0 || $pressure_only == 1 ]] || exit 1
[[ $critical_free_bytes =~ ^[0-9]+$ && $critical_free_percent =~ ^[0-9]+$ ]] || exit 1
[[ $image_min_age =~ ^[1-9][0-9]*h$ ]] || exit 1
[[ $stale_after_seconds =~ ^[1-9][0-9]*$ ]] || exit 1
[[ $lock_budget_seconds =~ ^[1-9][0-9]*$ ]] && ((lock_budget_seconds <= 40)) || exit 1
[[ $image_limit =~ ^[1-9][0-9]*$ ]] && ((image_limit <= 8)) || exit 1
[[ $container_limit =~ ^[1-9][0-9]*$ ]] && ((container_limit <= 8)) || exit 1
IFS=$' \t\n' read -r -d '' -a runner_units <<<"$runner_units_text" || true
((${#runner_units[@]} > 1)) || exit 1
[[ ${runner_units[0]} == "$primary_runner" && ${runner_units[1]} == "$podman_runner" ]] || exit 1
for ((i = 0; i < ${#runner_units[@]}; i++)); do
  [[ ${runner_units[i]} =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || exit 1
  for ((j = 0; j < i; j++)); do
    [[ ${runner_units[i]} != "${runner_units[j]}" ]] || exit 1
  done
done
[[ -d $state_dir && ! -L $state_dir ]] || skip aggregate_state_missing
# The service runs as root. Isolated unprivileged fixtures own their own state.
[[ $(stat -c '%u:%a' -- "$state_dir") == "$EUID:700" ]] || skip aggregate_state_untrusted

# Manual Docker mode is an exact operator allowlist, never an automatic policy.
# Read through a verified descriptor so replacement cannot change parsed bytes.
docker_volume_queue=''
if [[ -n $docker_volume_manifest ]]; then
  [[ -f $docker_volume_manifest && ! -L $docker_volume_manifest &&
    $(stat -c '%u:%a:%h' -- "$docker_volume_manifest") == "$EUID:600:1" ]] || fail docker_manifest_untrusted
  manifest_identity=$(stat -c '%d:%i:%u:%a:%h:%s' -- "$docker_volume_manifest") || fail docker_manifest_untrusted
  exec 8<"$docker_volume_manifest" || fail docker_manifest_untrusted
  [[ -f /proc/self/fd/8 && ! -L $docker_volume_manifest &&
    $(stat -Lc '%u:%a:%h' -- /proc/self/fd/8) == "$EUID:600:1" &&
    $(stat -Lc '%d:%i:%u:%a:%h:%s' -- /proc/self/fd/8) == "$manifest_identity" &&
    $(stat -c '%d:%i:%u:%a:%h:%s' -- "$docker_volume_manifest") == "$manifest_identity" ]] || fail docker_manifest_untrusted
  docker_volume_queue=$("$jq_bin" -ser '
    def name: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*\\z");
    def stamp: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})\\z");
    if length != 1 then error("manifest count") else .[0] end |
    if type == "object" and keys == ["volumes"] and (.volumes | type == "array") and
      all(.volumes[]; type == "object" and keys == ["created_at", "name"] and
        (.name | name) and (.created_at | stamp)) and
      ([.volumes[].name] | unique | length) == (.volumes | length)
    then [.volumes[] | [.name, .created_at] | @tsv] | join("\n") else error("invalid manifest") end
  ' <&8) || fail docker_manifest_invalid
  exec 8<&-
fi

available_bytes() {
  local path=$1 sample total available
  sample=$($df_bin --block-size=1 --output=size,avail "$path" | awk 'NR == 2 { print $1, $2 }') || return 1
  read -r total available <<<"$sample"
  [[ $total =~ ^[1-9][0-9]*$ && $available =~ ^[0-9]+$ ]] || return 1
  ((available <= total)) || return 1
  printf '%s %s\n' "$total" "$available"
}
# Capacity checks need no lock. The critical floor applies in either mode;
# pressure-only cleanup also exits before contending with runner starts.
sample=$(available_bytes "$disk_path") || skip disk_unreadable
read -r total available <<<"$sample"
((available >= critical_free_bytes && available * 100 >= total * critical_free_percent)) || skip below_critical_floor
sample=$(available_bytes "$store_path") || skip store_unreadable
read -r total available <<<"$sample"
if [[ $pressure_only == 1 ]]; then
  ((available * 100 <= total * (100 - trigger_used_percent))) || skip below_trigger
fi

exec 9>"$state_dir/lifecycle.lock"
flock -w 5 -x 9 || skip lifecycle_locked
lock_deadline=$((SECONDS + lock_budget_seconds))
[[ ! -e $fence && ! -L $fence ]] || fail cleanup_in_flight

# The guard's registry and transition markers are the authority for this
# aggregate. A configuration switch or unfinished transition must not turn
# into a cleanup opportunity.
[[ -f $state_dir/runner-units && ! -L $state_dir/runner-units ]] || skip runner_registry_missing
[[ $(cat "$state_dir/runner-units") == "$(printf '%s\n' "${runner_units[@]}")" ]] || skip runner_registry_mismatch
for unit in "${runner_units[@]:1}"; do
  [[ -d $state_dir/runners/$unit && ! -L $state_dir/runners/$unit ]] || skip runner_registry_missing
done
for path in "$state_dir"/runners/*; do
  [[ -e $path || -L $path ]] || continue
  known=0
  for unit in "${runner_units[@]:1}"; do
    [[ $path != "$state_dir/runners/$unit" ]] || known=1
  done
  ((known == 1)) && [[ -d $path && ! -L $path ]] || skip runner_registry_mismatch
done
for marker in owned pending teardown-required drain-pending resume-pending drain-disowned; do
  [[ ! -e $state_dir/$marker && ! -L $state_dir/$marker ]] || skip "transition_marker marker=$marker"
  for unit in "${runner_units[@]:1}"; do
    [[ ! -e $state_dir/runners/$unit/$marker && ! -L $state_dir/runners/$unit/$marker ]] ||
      skip "transition_marker marker=$marker"
  done
done

query_unit() {
  if [[ -n $docker_volume_manifest ]]; then
    local remaining=$((lock_deadline - SECONDS))
    ((remaining > 0)) || return 1
    ((remaining <= 5)) || remaining=5
    timeout -s KILL "${remaining}s" "$systemctl_bin" "$@"
  else
    timeout -k 2s 5s "$systemctl_bin" "$@"
  fi
}
[[ $(query_unit show --property=FreezerState --value forgejobuilds.slice) == running ]] || skip aggregate_frozen
query_unit is-active --quiet forgejo-runner-io-pressure-guard.service || skip guard_inactive
query_unit is-active --quiet forgejo-runner-aggregate-lifecycle.service || skip guard_inactive
query_unit is-active --quiet forgejo-runner-docker.service || skip engine_inactive
query_unit is-active --quiet forgejo-runner-podman.service || skip engine_inactive

for unit in "${runner_units[@]}"; do
  metadata=$(query_unit show --property=ActiveState --property=SubState \
    --property=MainPID --property=ControlPID --property=Job "$unit") || skip "runner_unreadable unit=$unit"
  [[ $(printf '%s\n' "$metadata" | wc -l) == 5 ]] || skip "runner_active unit=$unit"
  # systemctl renders the absence of a pending job as an empty Job= field.
  for expected in ActiveState=inactive SubState=dead MainPID=0 ControlPID=0 Job=; do
    printf '%s\n' "$metadata" | rg --quiet --fixed-strings --line-regexp "$expected" || skip "runner_active unit=$unit"
  done
done

[[ -S $docker_socket && -S $podman_socket ]] || skip engine_socket_missing

# Bind uncertain completion to the executions which could own the storage
# worker. Clean shutdown can reset systemd's current generation to zero;
# recovery separately requires terminal executions and positive empty cgroups.
# PID changes and successful GET requests are not completion evidence.
api_generations=''
for unit in forgejo-runner-docker.service forgejo-runner-podman.service; do
  generation=$(query_unit show --property=ExecMainStartTimestampMonotonic --value "$unit") || skip api_generation_unreadable
  [[ $generation =~ ^[1-9][0-9]*$ ]] || skip api_generation_invalid
  api_generations+="$unit $generation"$'\n'
done

# Each step starts only with enough lock budget left for its own timeout.
require_budget() {
  local needed=$1
  shift
  ((lock_deadline - SECONDS >= needed)) || skip "${budget_skip_reason:-lock_budget_exhausted} step=$*"
}
# Extra arguments go to curl before the URL.
request() {
  local socket=$1 method=$2 path=$3 max_time=$4 remaining
  shift 4
  remaining=$((lock_deadline - SECONDS))
  ((remaining >= 1)) || return 1
  ((max_time <= remaining)) || max_time=$remaining
  "$curl_bin" --silent --show-error --max-time "$max_time" --connect-timeout 2 \
    --max-filesize 8388608 --unix-socket "$socket" -X "$method" "$@" \
    "http://localhost$path"
}
api() {
  request "$1" "$2" "$3" "${4:-5}" --fail
}
# A client deadline bounds this helper, not server-side storage mutation.
# The atomic directory is an independent fence, including if its record is
# incomplete. No EXIT/signal trap clears it. Only this request's validated
# acknowledgement permits removal while the lifecycle lock is still held.
destructive_request() {
  local method=$1 path=$2 max_time=$3 kind=$4 id=${5:-} record identity response filter='' socket=$podman_socket
  local -a response_options=()
  [[ ! -e $fence && ! -L $fence ]] || fail cleanup_in_flight
  mkdir -m 0700 -- "$fence" || fail cleanup_in_flight
  identity=$(stat -c '%d:%i:%u:%a' -- "$fence") || fail cleanup_fence_record
  record="cleanup-v2 $$ $BASHPID $RANDOM $method $path"
  if [[ $kind == docker_volume ]]; then
    socket=$docker_socket
    record="cleanup-v3 $$ $BASHPID $RANDOM docker $method $path"
    response_options=(--dump-header "$fence/response-headers")
  fi
  printf '%s\n' "$record" >"$fence/owner" || fail cleanup_fence_record
  printf '%s' "$api_generations" >"$fence/api-generations" || fail cleanup_fence_record
  response=$fence/response
  request_status=$(request "$socket" "$method" "$path" "$max_time" \
    --output "$response" "${response_options[@]}" --write-out '%{http_code}') || fail "uncertain_request kind=$kind"
  [[ -f $response && ! -L $response ]] || fail "uncertain_response kind=$kind"
  (($(stat -c '%s' -- "$response") <= 8388608)) || fail "oversized_response kind=$kind"
  case "$kind:$request_status" in
    docker_volume:204)
      [[ ! -s $response ]] || fail "invalid_response kind=$kind"
      # curl follows HTTP 204 semantics and ignores even an illegally declared
      # body. Reject nonempty framing as well as bytes in the output file.
      [[ -f $fence/response-headers && ! -L $fence/response-headers ]] || fail "invalid_response kind=$kind"
      awk '
        { sub(/\r$/, ""); line=tolower($0) }
        /^HTTP\// { ack=($2 == "204") }
        line ~ /^content-length:/ {
          sub(/^content-length:[ \t]*/, "", line)
          if (line != "0") bad=1
        }
        line ~ /^transfer-encoding:/ { bad=1 }
        END { exit (bad || !ack) }
      ' "$fence/response-headers" || fail "invalid_response kind=$kind"
      ;;
    volume:204) [[ ! -s $response ]] || fail "invalid_response kind=$kind" ;;
    docker_volume:409)
      filter='type == "object" and (.message | type == "string" and length > 0)'
      ;;
    volume:409 | image:409)
      filter='type == "object" and .response == 409 and
        (.message | type == "string" and length > 0) and (.cause | type == "string")'
      ;;
    container:200 | exited:200)
      filter='type == "array" and length == 1 and all(.[];
        type == "object" and .Id == $id and (.Err == null or .Err == ""))'
      ;;
    # Podman answers 404 only when neither its database nor storage knows the
    # ID, before any removal; every other refusal is a 500.
    exited:404)
      filter='type == "object" and .response == 404 and
        (.message | type == "string" and length > 0) and (.cause | type == "string")'
      ;;
    image:200)
      filter='type == "array" and length > 0 and
        all(.[]; type == "object" and length == 1 and
          ((has("Deleted") and (.Deleted == $id or .Deleted == ("sha256:" + $id))) or
           (has("Untagged") and (.Untagged | type == "string" and length > 0)))) and
        any(.[]; .Deleted == $id or .Deleted == ("sha256:" + $id))'
      ;;
    *) fail "uncertain_status kind=$kind status=$request_status" ;;
  esac
  if [[ -n ${filter:-} ]]; then
    "$jq_bin" -se --arg id "$id" "length == 1 and (.[0] | $filter)" "$response" \
      >/dev/null 2>&1 || fail "invalid_response kind=$kind"
  fi
  [[ -d $fence && ! -L $fence && -f $fence/owner && ! -L $fence/owner ]] || fail cleanup_fence_ownership
  [[ $(stat -c '%d:%i:%u:%a' -- "$fence") == "$identity" &&
  $(stat -c '%u:%a' -- "$fence/owner") == "$EUID:600" &&
  $(cat "$fence/owner") == "$record" ]] || fail cleanup_fence_ownership
  # Remove only the known files, never recursively remove uncertain state.
  [[ -f $fence/api-generations && ! -L $fence/api-generations &&
    $(stat -c '%u:%a' -- "$fence/api-generations") == "$EUID:600" &&
    $(cat "$fence/api-generations") == "${api_generations%$'\n'}" ]] || fail cleanup_fence_ownership
  if [[ $kind == docker_volume ]]; then
    [[ -f $fence/response-headers && ! -L $fence/response-headers &&
      $(stat -c '%u:%a:%h' -- "$fence/response-headers") == "$EUID:600:1" ]] || fail cleanup_fence_ownership
    rm -- "$fence/response-headers" || fail cleanup_fence_clear
  fi
  rm -- "$response" "$fence/owner" "$fence/api-generations" || fail cleanup_fence_clear
  rmdir -- "$fence" || fail cleanup_fence_clear
}
# Exited and dead containers are safe to remove. With every runner inactive and
# the lifecycle lock held, no job can own a container, so two kinds of live
# container are leftovers from jobs whose cleanup never ran: a Buildx builder in
# any state, and any other container, apart from a runner job container, that
# is older than the longest job. Steps run with `docker run` inside a job, such
# as test databases, are not labelled, so age is the only sign of a leftover.
leftover_filter='
  def names: if (.Names | type) == "array" then .Names else [] end;
  def builder: (names | length > 0) and
    all(names[]; type == "string" and (ltrimstr("/") | test($pattern)));
  def job: any(names[]; type == "string" and (ltrimstr("/") | startswith("FORGEJO-ACTIONS-TASK-")));
  def terminal: .State == "exited" or .State == "dead";
  def stale: (.Created | type == "number") and .Created <= now - $stale_after;
  def leftover: builder or ((terminal | not) and stale and (job | not));
'
# Skips unless every container on the engine is safe to remove, logging an
# unreadable API separately from live containers.
require_terminal() {
  local engine=$1 socket=$2 allow_leftovers=$3 live_reason=${4:-containers_live} containers status=0
  require_budget 5 "check_containers engine=$engine"
  containers=$(api "$socket" GET '/containers/json?all=1') || skip "engine_api_unavailable engine=$engine"
  "$jq_bin" -e --arg pattern "$builder_pattern" --argjson stale_after "$stale_after_seconds" \
    --argjson allow_leftovers "$allow_leftovers" "$leftover_filter"'
    if type != "array" then error("not a container list") else all(.[];
      (.State | type == "string") and (terminal or ($allow_leftovers and leftover))) end' \
    <<<"$containers" >/dev/null 2>&1 || status=$?
  ((status != 1)) || skip "$live_reason engine=$engine"
  ((status == 0)) || skip "engine_api_invalid engine=$engine"
}
safe_to_prune() {
  require_terminal docker "$docker_socket" false
  require_terminal podman "$podman_socket" false
}

# Docker mode never enters any Podman mutation stage. Validate both complete
# inventories, including mount references from stopped Docker containers.
if [[ -n $docker_volume_manifest ]]; then
  docker_references=''
  for engine in docker podman; do
    socket=$docker_socket
    [[ $engine != podman ]] || socket=$podman_socket
    require_budget 5 "check_containers engine=$engine"
    containers=$(api "$socket" GET '/containers/json?all=1') || skip "engine_api_unavailable engine=$engine"
    references=$("$jq_bin" -ser --arg engine "$engine" '
      def name: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*\\z");
      if length != 1 then error("snapshot count") else .[0] end |
      if type == "array" and all(.[]; type == "object" and
          (.Id | type == "string" and test("^[0-9a-f]{64}\\z")) and
          (.Created | type == "number" and . >= 0 and floor == .) and
          (.State == "exited" or .State == "dead") and
          (if $engine == "docker" then
            (.Mounts | type == "array" and all(.[]; type == "object" and
              (.Type == "bind" or .Type == "tmpfs" or .Type == "volume" or .Type == "image" or .Type == "npipe") and
              (if .Type == "volume" then (.Name | name) else true end)))
           else true end)) and ([.[].Id] | unique | length) == length
      then [.[] | select($engine == "docker") | .Mounts[] |
        select(.Type == "volume") | .Name] | join("\n")
      else error("invalid terminal inventory") end
    ' <<<"$containers") || skip "engine_api_invalid engine=$engine"
    [[ $engine != docker ]] || docker_references=$references
  done
  attempted_volumes=0
  while IFS=$'\t' read -r volume created_at; do
    [[ -n $volume ]] || continue
    if [[ $'\n'$docker_references$'\n' == *$'\n'"$volume"$'\n'* ]]; then
      printf 'kept_docker_volume name=%s reason=referenced\n' "$volume"
      continue
    fi
    ((attempted_volumes < 2)) || skip 'bounded_partial cause=cap step=remove_docker_volume'
    budget_skip_reason='bounded_partial cause=budget'
    require_budget 5 inspect_docker_volume
    # Inspect is read-only: a 404 may report absence, but never acknowledges a
    # dispatched DELETE. Capture HTTP status separately from the JSON body.
    inspected=$(request "$docker_socket" GET "/volumes/$volume" 5 --write-out $'\n%{http_code}') || skip engine_api_unavailable
    inspect_status=${inspected##*$'\n'}
    inspected=${inspected%$'\n'*}
    if [[ $inspect_status == 404 ]]; then
      printf 'kept_docker_volume name=%s reason=absent\n' "$volume"
      continue
    fi
    [[ $inspect_status == 200 ]] || skip engine_api_unavailable
    "$jq_bin" -se --arg name "$volume" --arg created_at "$created_at" '
      length == 1 and (.[0] | type == "object" and .Name == $name and
        .CreatedAt == $created_at and .Driver == "local" and .Scope == "local" and
        (has("Options") and (.Options == null or .Options == {})))
    ' <<<"$inspected" >/dev/null 2>&1 || skip docker_volume_inspect_mismatch
    require_budget 25 remove_docker_volume
    attempted_volumes=$((attempted_volumes + 1))
    destructive_request DELETE "/volumes/$volume?force=false" 25 docker_volume "$volume"
    case $request_status in
      204) printf 'removed_docker_volume name=%s\n' "$volume" ;;
      409) printf 'kept_docker_volume name=%s reason=in_use\n' "$volume" ;;
    esac
  done <<<"$docker_volume_queue"
  printf 'docker_volume_pass attempts=%s\n' "$attempted_volumes"
  exit 0
fi

require_terminal docker "$docker_socket" false
require_terminal podman "$podman_socket" true

# Validate both complete snapshots before any container mutation. One shared
# newest-first queue covers live leftovers, Buildx builders and exited/dead
# containers. Compatible seconds plus native fractions order creation, then ID.
# This is a heuristic: skipped dependents or clock changes can still cause a
# refusal, which retains the completion fence. Never remove pod members/infra.
require_budget 5 list_containers
containers=$(api "$podman_socket" GET '/containers/json?all=1') || skip "engine_api_unavailable engine=podman"
require_budget 5 list_pod_members
native_containers=$(api "$podman_socket" GET "$libpod/containers/json?all=true") || skip "engine_api_unavailable engine=podman"
container_queue=$(printf '%s\n%s\n' "$containers" "$native_containers" | "$jq_bin" -sr \
  --arg pattern "$builder_pattern" --argjson stale_after "$stale_after_seconds" "$leftover_filter"'
  def hex: type == "string" and test("^[0-9a-f]{64}$");
  def stamp: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.(?<f>[0-9]{1,9}))?(Z|[+-][0-9]{2}:[0-9]{2})$";
  if length != 2 or (.[0] | type != "array") or (.[1] | type != "array")
    then error("not container lists") else . end |
  .[1] as $native | .[0] |
  if all($native[]; type == "object" and (.Id | hex) and
      (.Pod | type == "string" and (. == "" or hex)) and (.IsInfra | type == "boolean") and
      (.Created | type == "string" and test(stamp)))
    then . else error("invalid native container list") end |
  if ([$native[] | .Id] | unique | length) == ($native | length) then . else error("duplicate containers") end |
  ($native | map({key: .Id, value: {standalone: (.Pod == "" and (.IsInfra | not)),
    nanos: (.Created | capture(stamp) | (.f // "") + "000000000" | .[:9] | tonumber)}}) |
    from_entries) as $known |
  if all(.[]; type == "object" and (.State | type == "string") and (.Id | hex) and
      (.Created | type == "number" and . >= 0 and floor == .) and
      ($known[.Id] | type == "object"))
    then . else error("invalid container list") end |
  if ([.[] | .Id] | unique | length) == length then . else error("duplicate containers") end |
  map(select((leftover or terminal) and $known[.Id].standalone)) | sort_by(.Created, $known[.Id].nanos, .Id) | reverse |
  .[] | "\(.Id) \(if leftover then (if builder then "builder" else "stale" end) else "exited" end) \(names[0] // "-" | ltrimstr("/") | gsub("[^A-Za-z0-9_.-]"; "_"))"
') || skip "engine_api_invalid engine=podman"
removed_leftovers=0
removed_containers=0
attempted_containers=0
container_capped=0
unset budget_skip_reason
while read -r id kind name; do
  [[ -n $id ]] || continue
  # Only a positively unattempted candidate justifies a container partial skip.
  budget_skip_reason='bounded_partial cause=budget'
  if ((attempted_containers >= container_limit)); then
    container_capped=1
    break
  fi
  require_budget 15 remove_container
  attempted_containers=$((attempted_containers + 1))
  if [[ $kind == exited ]]; then
    destructive_request DELETE "$libpod/containers/$id?force=false" 15 exited "$id"
    case $request_status in
      200)
        printf 'removed_container id=%s\n' "$id"
        removed_containers=$((removed_containers + 1))
        ;;
      404) printf 'kept_container id=%s reason=gone\n' "$id" ;;
    esac
  else
    destructive_request DELETE "$libpod/containers/$id?force=true&timeout=10" 15 container "$id"
    printf 'removed_leftover kind=%s name=%s\n' "$kind" "$name"
    removed_leftovers=$((removed_leftovers + 1))
  fi
  unset budget_skip_reason
done <<<"$container_queue"
# Safe live leftovers beyond the prefix are normal bounded partial work.
# Unexpected live containers still stop the pass, and no volume/image stage
# starts until both engines are terminal.
require_terminal docker "$docker_socket" false
require_terminal podman "$podman_socket" true
if ((container_capped)); then
  require_terminal podman "$podman_socket" false 'bounded_partial cause=cap'
else
  require_terminal podman "$podman_socket" false
fi
unset budget_skip_reason

# Podman refuses, with 409, to remove a volume that a container still uses;
# such a volume is kept and reported instead of forced. Any other failure
# retains the fence and ends the run before another mutation.
volumes=$(api "$podman_socket" GET "$libpod/volumes/json" |
  "$jq_bin" -r --arg pattern "$builder_volume_pattern" \
    '.[] | .Name | select(type == "string" and test($pattern))') || skip "engine_api_unavailable engine=podman"
removed_volumes=0
for volume in $volumes; do
  [[ $volume =~ $builder_volume_pattern ]] || exit 1
  require_budget 10 "remove_builder_volume name=$volume"
  destructive_request DELETE "$libpod/volumes/$volume" 10 volume
  case $request_status in
    204)
      printf 'removed_builder_volume name=%s\n' "$volume"
      removed_volumes=$((removed_volumes + 1))
      ;;
    409) printf 'kept_builder_volume name=%s reason=in_use\n' "$volume" ;;
  esac
done

safe_to_prune
require_budget 5 list_images
images=$(api "$podman_socket" GET '/images/json?all=true') || skip "engine_api_unavailable engine=podman"
# Creation age is not pull or last-use age. Validate the complete snapshot,
# skip referenced images, multiple tags and parents, then sort oldest/ID for
# stable capped work. force=false/noprune=true retain server conflict checks
# and prohibit recursive parent deletion. No image-prune/cache-mount endpoint.
image_ids=$("$jq_bin" -sr --arg age "${image_min_age%h}" --argjson cap "$image_limit" '
  def id: sub("^sha256:"; "");
  ($age | tonumber * 3600) as $age |
  if length != 1 or (.[0] | type != "array") then error("not an image list") else .[0] end |
  if all(.[]; type == "object" and
      (.Id | type == "string" and (id | test("^[0-9a-f]{64}$"))) and
      (.Created | type == "number" and . >= 0 and floor == .) and
      (.Containers | type == "number" and . >= 0 and floor == .) and
      (.RepoTags | type == "array" and all(.[]; type == "string")) and
      (.ParentId | type == "string" and (. == "" or (id | test("^[0-9a-f]{64}$")))))
    then . else error("invalid image list") end |
  if ([.[] | .Id | id] | unique | length) == length then . else error("duplicate images") end |
  [.[] | .ParentId | id | select(. != "")] as $parents |
  map(select(.Containers == 0 and .Created <= now - $age and (.RepoTags | length) <= 1) |
    select((.Id | id) as $i | $parents | index($i) == null)) |
  sort_by(.Created, .Id) | .[:$cap][] | .Id | id
' <<<"$images") || skip "engine_api_invalid engine=podman"
removed_images=0
while read -r id; do
  [[ -n $id ]] || continue
  require_budget 15 remove_image
  destructive_request DELETE "/images/$id?force=false&noprune=true" 15 image "$id"
  if [[ $request_status == 200 ]]; then
    removed_images=$((removed_images + 1))
  else
    printf 'kept_image id=%s reason=conflict\n' "$id"
  fi
done <<<"$image_ids"

if sample=$(available_bytes "$store_path"); then
  read -r _ available_after <<<"$sample"
  reclaimed=$((available_after - available))
else
  reclaimed=unknown
fi
printf 'pruned leftovers=%s builder_volumes=%s failed_builder_volumes=0 containers=%s image_min_age=%s images=%s reclaimed_bytes=%s\n' \
  "$removed_leftovers" "$removed_volumes" "$removed_containers" "$image_min_age" "$removed_images" "$reclaimed"
