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
fence=$state_dir/cleanup-in-flight
umask 077
runner_units=(forgejo-actions-runner.service forgejo-podman-runner.service)
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
[[ $critical_free_bytes =~ ^[0-9]+$ && $critical_free_percent =~ ^[0-9]+$ ]] || exit 1
[[ $image_min_age =~ ^[1-9][0-9]*h$ ]] || exit 1
[[ $stale_after_seconds =~ ^[1-9][0-9]*$ ]] || exit 1
[[ $lock_budget_seconds =~ ^[1-9][0-9]*$ ]] && ((lock_budget_seconds <= 40)) || exit 1
[[ $image_limit =~ ^[1-9][0-9]*$ ]] && ((image_limit <= 8)) || exit 1
[[ -d $state_dir && ! -L $state_dir ]] || skip aggregate_state_missing
# The service runs as root. Isolated unprivileged fixtures own their own state.
[[ $(stat -c '%u:%a' -- "$state_dir") == "$EUID:700" ]] || skip aggregate_state_untrusted

available_bytes() {
  local path=$1 sample total available
  sample=$($df_bin --block-size=1 --output=size,avail "$path" | awk 'NR == 2 { print $1, $2 }') || return 1
  read -r total available <<< "$sample"
  [[ $total =~ ^[1-9][0-9]*$ && $available =~ ^[0-9]+$ ]] || return 1
  ((available <= total)) || return 1
  printf '%s %s\n' "$total" "$available"
}
# Disk usage needs no lock, so most runs end here without contending with
# runner starts.
sample=$(available_bytes "$disk_path") || skip disk_unreadable
read -r total available <<< "$sample"
((available >= critical_free_bytes && available * 100 >= total * critical_free_percent)) || skip below_critical_floor
sample=$(available_bytes "$store_path") || skip store_unreadable
read -r total available <<< "$sample"
((available * 100 <= total * (100 - trigger_used_percent))) || skip below_trigger

exec 9>"$state_dir/lifecycle.lock"
flock -w 5 -x 9 || skip lifecycle_locked
lock_deadline=$((SECONDS + lock_budget_seconds))
[[ ! -e $fence && ! -L $fence ]] || fail cleanup_in_flight

# The guard's registry and transition markers are the authority for this
# aggregate. A configuration switch or unfinished transition must not turn
# into a cleanup opportunity.
[[ -f $state_dir/runner-units && ! -L $state_dir/runner-units ]] || skip runner_registry_missing
[[ $(cat "$state_dir/runner-units") == "$(printf '%s\n' "${runner_units[@]}")" ]] || skip runner_registry_mismatch
[[ -d $state_dir/runners/${runner_units[1]} && ! -L $state_dir/runners/${runner_units[1]} ]] || skip runner_registry_missing
for path in "$state_dir"/runners/*; do
  [[ -e $path || -L $path ]] || continue
  [[ $path == "$state_dir/runners/${runner_units[1]}" && -d $path && ! -L $path ]] || skip runner_registry_mismatch
done
for marker in owned pending teardown-required drain-pending resume-pending drain-disowned; do
  [[ ! -e $state_dir/$marker && ! -L $state_dir/$marker ]] || skip "transition_marker marker=$marker"
  [[ ! -e $state_dir/runners/${runner_units[1]}/$marker && ! -L $state_dir/runners/${runner_units[1]}/$marker ]] ||
    skip "transition_marker marker=$marker"
done

query_unit() {
  timeout -k 2s 5s "$systemctl_bin" "$@"
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
  ((lock_deadline - SECONDS >= needed)) || skip "lock_budget_exhausted step=$*"
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
  local method=$1 path=$2 max_time=$3 kind=$4 id=${5:-} record identity response filter=''
  [[ ! -e $fence && ! -L $fence ]] || fail cleanup_in_flight
  mkdir -m 0700 -- "$fence" || fail cleanup_in_flight
  identity=$(stat -c '%d:%i:%u:%a' -- "$fence") || fail cleanup_fence_record
  record="cleanup-v2 $$ $BASHPID $RANDOM $method $path"
  printf '%s\n' "$record" > "$fence/owner" || fail cleanup_fence_record
  printf '%s' "$api_generations" > "$fence/api-generations" || fail cleanup_fence_record
  response=$fence/response
  request_status=$(request "$podman_socket" "$method" "$path" "$max_time" \
    --output "$response" --write-out '%{http_code}') || fail "uncertain_request kind=$kind"
  [[ -f $response && ! -L $response ]] || fail "uncertain_response kind=$kind"
  (( $(stat -c '%s' -- "$response") <= 8388608 )) || fail "oversized_response kind=$kind"
  case "$kind:$request_status" in
    volume:204) [[ ! -s $response ]] || fail "invalid_response kind=$kind" ;;
    volume:409 | image:409)
      filter='type == "object" and .response == 409 and
        (.message | type == "string" and length > 0) and (.cause | type == "string")'
      ;;
    container:200)
      filter='type == "array" and length == 1 and all(.[];
        type == "object" and .Id == $id and (.Err == null or .Err == ""))'
      ;;
    prune:200)
      filter='type == "array" and all(.[]; type == "object" and
        (.Id | type == "string" and test("^[0-9a-f]{64}$")) and
        (.Size | type == "number" and . >= 0 and floor == .) and
        (.Err == null or .Err == ""))'
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
  rm -- "$response" "$fence/owner" "$fence/api-generations" || fail cleanup_fence_clear
  rmdir -- "$fence" || fail cleanup_fence_clear
}
# Exited and dead containers are safe to prune. With both runners inactive and
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
# Skips unless every container on the engine is safe to prune, logging an
# unreadable API separately from live containers.
require_terminal() {
  local engine=$1 socket=$2 allow_leftovers=$3 containers status=0
  require_budget 5 "check_containers engine=$engine"
  containers=$(api "$socket" GET '/containers/json?all=1') || skip "engine_api_unavailable engine=$engine"
  "$jq_bin" -e --arg pattern "$builder_pattern" --argjson stale_after "$stale_after_seconds" \
    --argjson allow_leftovers "$allow_leftovers" "$leftover_filter"'
    if type != "array" then error("not a container list") else all(.[];
      (.State | type == "string") and (terminal or ($allow_leftovers and leftover))) end' \
    <<< "$containers" >/dev/null 2>&1 || status=$?
  ((status != 1)) || skip "containers_live engine=$engine"
  ((status == 0)) || skip "engine_api_invalid engine=$engine"
}
safe_to_prune() {
  require_terminal docker "$docker_socket" false
  require_terminal podman "$podman_socket" false
}

require_terminal docker "$docker_socket" false
require_terminal podman "$podman_socket" true

# Leftovers are removed by ID; the log names them by kind and first name.
leftovers=$(api "$podman_socket" GET '/containers/json?all=1' |
  "$jq_bin" -r --arg pattern "$builder_pattern" --argjson stale_after "$stale_after_seconds" "$leftover_filter"'
    .[] | select(leftover) |
      "\(.Id) \(if builder then "builder" else "stale" end) \(names[0] // "-" | ltrimstr("/"))"') ||
  skip "engine_api_unavailable engine=podman"
removed_leftovers=0
while read -r id kind name; do
  [[ -n $id ]] || continue
  [[ $id =~ ^[0-9a-f]{64}$ ]] || fail "remove_leftover id=invalid"
  name=${name//[^A-Za-z0-9_.-]/_}
  require_budget 15 "remove_leftover name=$name"
  destructive_request DELETE "$libpod/containers/$id?force=true&timeout=10" 15 container "$id"
  printf 'removed_leftover kind=%s name=%s\n' "$kind" "$name"
  removed_leftovers=$((removed_leftovers + 1))
done <<< "$leftovers"
safe_to_prune

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

# Podman's native API excludes running containers and images still referenced
# by containers. This service never touches pods, networks, volumes other than
# Buildx builder state, or the local Podman storage CLI.
safe_to_prune
require_budget 10 prune_containers
destructive_request POST "$libpod/containers/prune" 10 prune
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
' <<< "$images") || skip "engine_api_invalid engine=podman"
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
done <<< "$image_ids"

if sample=$(available_bytes "$store_path"); then
  read -r _ available_after <<< "$sample"
  reclaimed=$((available_after - available))
else
  reclaimed=unknown
fi
printf 'pruned leftovers=%s builder_volumes=%s failed_builder_volumes=0 image_min_age=%s images=%s reclaimed_bytes=%s\n' \
  "$removed_leftovers" "$removed_volumes" "$image_min_age" "$removed_images" "$reclaimed"
