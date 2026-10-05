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
runner_units=(forgejo-actions-runner.service forgejo-podman-runner.service)
# Buildx docker-container builders run as buildx_buildkit_<node> and keep their
# BuildKit state in buildx_buildkit_<node>_state.
builder_pattern='^buildx_buildkit_[A-Za-z0-9][A-Za-z0-9_.-]*$'
builder_volume_pattern='^buildx_buildkit_[A-Za-z0-9][A-Za-z0-9_.-]*_state$'
# Podman serves its native API only under a version prefix.
libpod=/v5.0.0/libpod

# Every skipped run logs its first failed guard so the journal shows whether
# the cleanup ever reaches its idle window. A skip after a failed volume
# removal still fails the run.
failed_volumes=0
skip() {
  printf 'skipped reason=%s\n' "$*"
  ((failed_volumes == 0)) || printf 'failed_builder_volumes=%s\n' "$failed_volumes"
  exit $((failed_volumes > 0))
}
fail() {
  printf 'failed step=%s\n' "$*" >&2
  exit 1
}

[[ $trigger_used_percent =~ ^[1-9][0-9]?$ ]] || exit 1
[[ $critical_free_bytes =~ ^[0-9]+$ && $critical_free_percent =~ ^[0-9]+$ ]] || exit 1
[[ $image_min_age =~ ^[1-9][0-9]*h$ ]] || exit 1
[[ $stale_after_seconds =~ ^[1-9][0-9]*$ ]] || exit 1
[[ $lock_budget_seconds =~ ^[1-9][0-9]*$ ]] || exit 1
[[ -d $state_dir && ! -L $state_dir ]] || skip aggregate_state_missing

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
  for expected in ActiveState=inactive SubState=dead MainPID=0 ControlPID=0 Job=0; do
    printf '%s\n' "$metadata" | rg --quiet --fixed-strings --line-regexp "$expected" || skip "runner_active unit=$unit"
  done
done

[[ -S $docker_socket && -S $podman_socket ]] || skip engine_socket_missing

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
  api "$podman_socket" DELETE "$libpod/containers/$id?force=true&timeout=10" 15 >/dev/null ||
    fail "remove_leftover name=$name"
  printf 'removed_leftover kind=%s name=%s\n' "$kind" "$name"
  removed_leftovers=$((removed_leftovers + 1))
done <<< "$leftovers"
safe_to_prune

# Podman refuses, with 409, to remove a volume that a container still uses;
# such a volume is kept and reported instead of forced. Any other failure is
# reported separately and fails the run after the prune.
volumes=$(api "$podman_socket" GET "$libpod/volumes/json" |
  "$jq_bin" -r --arg pattern "$builder_volume_pattern" \
    '.[] | .Name | select(type == "string" and test($pattern))') || skip "engine_api_unavailable engine=podman"
removed_volumes=0
for volume in $volumes; do
  [[ $volume =~ $builder_volume_pattern ]] || exit 1
  require_budget 10 "remove_builder_volume name=$volume"
  status=$(request "$podman_socket" DELETE "$libpod/volumes/$volume" 10 \
    --output /dev/null --write-out '%{http_code}') || status=unavailable
  case $status in
    200 | 204)
      printf 'removed_builder_volume name=%s\n' "$volume"
      removed_volumes=$((removed_volumes + 1))
      ;;
    409) printf 'kept_builder_volume name=%s reason=in_use\n' "$volume" ;;
    *)
      printf 'failed_builder_volume name=%s status=%s\n' "$volume" "$status"
      failed_volumes=$((failed_volumes + 1))
      ;;
  esac
done

# Podman's native API excludes running containers and images still referenced
# by containers. This service never touches pods, networks, volumes other than
# Buildx builder state, or the local Podman storage CLI.
safe_to_prune
require_budget 10 prune_containers
api "$podman_socket" POST "$libpod/containers/prune" 10 >/dev/null || fail prune_containers
safe_to_prune
image_filters=$("$jq_bin" -rn --arg age "$image_min_age" '{until: [$age], dangling: ["false"]} | tojson | @uri')
require_budget 15 prune_images
api "$podman_socket" POST "$libpod/images/prune?filters=$image_filters" 15 >/dev/null || fail prune_images

if sample=$(available_bytes "$store_path"); then
  read -r _ available_after <<< "$sample"
  reclaimed=$((available_after - available))
else
  reclaimed=unknown
fi
printf 'pruned leftovers=%s builder_volumes=%s failed_builder_volumes=%s image_min_age=%s reclaimed_bytes=%s\n' \
  "$removed_leftovers" "$removed_volumes" "$failed_volumes" "$image_min_age" "$reclaimed"
((failed_volumes == 0))
