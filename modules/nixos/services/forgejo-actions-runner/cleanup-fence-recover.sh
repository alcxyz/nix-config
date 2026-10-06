#!/usr/bin/env bash
set -euo pipefail

state_dir=${STATE_DIR:-/run/forgejo-runner-aggregate-pressure}
cgroup_root=${CGROUP_ROOT:-/sys/fs/cgroup}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
fence=$state_dir/cleanup-in-flight
runner_units=(forgejo-actions-runner.service forgejo-podman-runner.service)
api_units=(forgejo-runner-docker.service forgejo-runner-podman.service)
deadline=$((SECONDS + 60))
fail() {
  printf 'cleanup fence recovery refused: %s\n' "$1" >&2
  exit 1
}
query() {
  local remaining=$((deadline - SECONDS))
  ((remaining > 0)) || fail deadline
  ((remaining <= 5)) || remaining=5
  timeout --foreground "${remaining}s" "$systemctl_bin" show "$@"
}
trusted_dir() {
  [[ -d $1 && ! -L $1 && $(stat -c '%u:%a' -- "$1") == "$EUID:700" ]]
}
trusted_file() {
  [[ -f $1 && ! -L $1 && $(stat -c '%u:%a:%h' -- "$1") == "$EUID:600:1" ]]
}
trusted_dir "$state_dir" || fail state_directory
[[ ! -L $state_dir/lifecycle.lock ]] || fail lifecycle_lock
exec 9>"$state_dir/lifecycle.lock"
flock -w 60 -x 9 || fail lifecycle_locked

trusted_dir "$fence" || fail fence_directory
trusted_file "$fence/owner" || fail fence_owner
trusted_file "$fence/api-generations" || fail fence_generations
identity=$(stat -c '%d:%i:%u:%a' -- "$fence")
owner_identity=$(stat -c '%d:%i:%u:%a:%h' -- "$fence/owner")
generation_identity=$(stat -c '%d:%i:%u:%a:%h' -- "$fence/api-generations")
owner=$(cat "$fence/owner")
[[ $(wc -l <"$fence/owner") == 1 && $owner =~ ^cleanup-v2\ [1-9][0-9]*\ [1-9][0-9]*\ [0-9]+\ (DELETE|POST)\ /[^[:space:]]+$ ]] || fail fence_format
read -r _ _ _ _ method request_path <<<"$owner"
case "$method:$request_path" in
  POST:/v5.0.0/libpod/containers/prune) ;;
  DELETE:*)
    [[ $request_path =~ ^/images/[0-9a-f]{64}\?force=false\&noprune=true$ ||
      $request_path =~ ^/v5\.0\.0/libpod/containers/[0-9a-f]{64}\?force=true\&timeout=10$ ||
      $request_path =~ ^/v5\.0\.0/libpod/volumes/buildx_buildkit_[A-Za-z0-9][A-Za-z0-9_.-]*_state$ ]] || fail fence_format
    ;;
  *) fail fence_format ;;
esac
generations=$(cat "$fence/api-generations")
mapfile -t generation_lines <"$fence/api-generations"
[[ ${#generation_lines[@]} == 2 && $(wc -l <"$fence/api-generations") == 2 ]] || fail generation_format
for i in 0 1; do
  read -r recorded_unit generation extra <<<"${generation_lines[$i]}"
  [[ $recorded_unit == "${api_units[$i]}" && $generation =~ ^[1-9][0-9]*$ && -z $extra &&
    ${generation_lines[$i]} == "$recorded_unit $generation" ]] || fail generation_format
done
declare -A file_identities=()
shopt -s nullglob dotglob
for path in "$fence"/*; do
  case "$path" in
    "$fence/owner" | "$fence/api-generations" | "$fence/response") ;;
    *) fail unknown_fence_file ;;
  esac
  trusted_file "$path" || fail fence_file
  file_identities[$path]=$(stat -c '%d:%i:%u:%a:%h' -- "$path")
done

[[ -f $state_dir/runner-units && ! -L $state_dir/runner-units &&
  $(wc -l <"$state_dir/runner-units") == 2 &&
  $(cat "$state_dir/runner-units") == "$(printf '%s\n' "${runner_units[@]}")" ]] || fail runner_registry
[[ -d $state_dir/runners && ! -L $state_dir/runners ]] || fail runner_registry
paths=("$state_dir/runners"/*)
[[ ${#paths[@]} == 1 && ${paths[0]} == "$state_dir/runners/${runner_units[1]}" &&
  -d ${paths[0]} && ! -L ${paths[0]} ]] || fail runner_registry
for directory in "$state_dir" "${paths[0]}"; do
  for marker in owned pending teardown-required drain-pending resume-pending drain-disowned; do
    [[ ! -e $directory/$marker && ! -L $directory/$marker ]] || fail transition_marker
  done
done

# A terminal unit may retain its empty cgroup or systemd may have removed it.
# The aggregate itself must exist: absence is not positive empty evidence.
empty_cgroup() {
  local relative=$1 cgroup="$cgroup_root$1" events
  [[ $relative == /* && $(readlink -f -- "$cgroup") == "$cgroup" &&
  -f $cgroup/cgroup.events ]] || fail cgroup_path
  events=$(cat "$cgroup/cgroup.events") || fail cgroup_events
  [[ $(awk '$1 == "populated" { print $2 }' <<<"$events") == 0 &&
  $(awk '$1 == "frozen" { print $2 }' <<<"$events") == 0 ]] || fail cgroup_workers_or_freezer
}
snapshot() {
  local unit metadata line key value expected_scope index=0
  local -A fields
  for unit in "${runner_units[@]}" "${api_units[@]}"; do
    fields=()
    metadata=$(query --property=LoadState --property=ActiveState --property=SubState \
      --property=MainPID --property=ControlPID --property=Job --property=ControlGroup \
      --property=ExecMainStartTimestampMonotonic "$unit") || fail unit_query
    while IFS= read -r line; do
      [[ $line == *=* ]] || fail unit_metadata
      key=${line%%=*}
      value=${line#*=}
      case "$key" in
        LoadState | ActiveState | SubState | MainPID | ControlPID | Job | ControlGroup | ExecMainStartTimestampMonotonic) ;;
        *) fail unit_metadata ;;
      esac
      [[ ! -v fields[$key] ]] || fail unit_metadata
      fields[$key]=$value
    done <<<"$metadata"
    [[ ${#fields[@]} == 8 && ${fields[LoadState]-} == loaded &&
      ${fields[MainPID]-} == 0 && ${fields[ControlPID]-} == 0 &&
      ${fields[ExecMainStartTimestampMonotonic]-} =~ ^[0-9]+$ &&
      -v fields[Job] && -z ${fields[Job]} ]] || fail unit_not_terminal
    case "${fields[ActiveState]-}:${fields[SubState]-}" in
      inactive:dead | failed:failed) ;;
      *) fail unit_not_terminal ;;
    esac
    if ((index >= 2)); then
      # systemd clears ExecMainStartTimestampMonotonic after a clean stop.
      # Zero is accepted only with the complete terminal + no-job/PID
      # proof above and positive empty-worker evidence below. A different
      # positive execution generation never substitutes for completion.
      if [[ ${fields[ExecMainStartTimestampMonotonic]-} == 0 ]]; then
        : # Includes a failed ExecCondition cancelled before ExecStart.
      else
        [[ "$unit ${fields[ExecMainStartTimestampMonotonic]-}" == "${generation_lines[$((index - 2))]}" ]] || fail api_generation_changed
      fi
      expected_scope=/forgejobuilds.slice/$unit
    else
      expected_scope=/system.slice/$unit
    fi
    [[ -v fields[ControlGroup] ]] || fail unit_metadata
    if [[ -n ${fields[ControlGroup]} ]]; then
      [[ ${fields[ControlGroup]} == "$expected_scope" ]] || fail unit_cgroup
      empty_cgroup "$expected_scope"
    fi
    printf '%s\n%s\n' "$unit" "$metadata"
    index=$((index + 1))
  done
  metadata=$(query --property=LoadState --property=ActiveState --property=ControlGroup \
    --property=FreezerState --property=Job forgejobuilds.slice) || fail aggregate_query
  [[ $(wc -l <<<"$metadata") == 5 ]] || fail aggregate_metadata
  for line in LoadState=loaded ActiveState=active ControlGroup=/forgejobuilds.slice FreezerState=running Job=; do
    [[ $'\n'$metadata$'\n' == *$'\n'"$line"$'\n'* ]] || fail aggregate_state
  done
  empty_cgroup /forgejobuilds.slice
  printf '%s\n' "$metadata"
}
# Both APIs and runners take this same lock in ExecCondition. A queued or
# activating start has Job/ActiveState/ControlPID evidence even after its gate
# passed. Repeat complete evidence under exclusion; stable counts alone cannot
# establish worker termination or completion of the recorded API generation.
before=$(snapshot) || fail terminal_evidence
after=$(snapshot) || fail terminal_evidence
[[ $before == "$after" ]] || fail generation_or_lifecycle_changed
((SECONDS < deadline)) || fail deadline

trusted_dir "$fence" || fail fence_changed
trusted_file "$fence/owner" || fail fence_changed
trusted_file "$fence/api-generations" || fail fence_changed
[[ $(stat -c '%d:%i:%u:%a' -- "$fence") == "$identity" &&
$(stat -c '%d:%i:%u:%a:%h' -- "$fence/owner") == "$owner_identity" &&
$(stat -c '%d:%i:%u:%a:%h' -- "$fence/api-generations") == "$generation_identity" &&
$(cat "$fence/owner") == "$owner" && $(cat "$fence/api-generations") == "$generations" ]] || fail fence_changed
paths=("$fence"/*)
[[ ${#paths[@]} == "${#file_identities[@]}" ]] || fail fence_changed
for path in "${paths[@]}"; do
  trusted_file "$path" && [[ -v file_identities[$path] &&
    $(stat -c '%d:%i:%u:%a:%h' -- "$path") == "${file_identities[$path]}" ]] || fail fence_changed
done
rm -- "${paths[@]}"
rmdir -- "$fence"
printf 'cleanup fence cleared after terminal execution and worker proof\n'
