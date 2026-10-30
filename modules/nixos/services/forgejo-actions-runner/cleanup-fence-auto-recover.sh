#!/usr/bin/env bash
set -euo pipefail

state_dir=${STATE_DIR:-/run/forgejo-runner-aggregate-pressure}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
# The installed recovery command, whose proof decides whether the fence clears.
recover_bin=${RECOVER_BIN:-forgejo-runner-cleanup-fence-recover}
# Stopping an API kills a removal that outlived its client. Wait until the
# fence has been unchanged this long, so the removal has most likely finished.
# Age is never completion evidence: the recovery's terminal proof is.
settle_seconds=${SETTLE_SECONDS:-300}
stop_timeout_seconds=${STOP_TIMEOUT_SECONDS:-420}
start_timeout_seconds=${START_TIMEOUT_SECONDS:-300}
runner_units_text=${RUNNER_UNITS:-}
fence=$state_dir/cleanup-in-flight
api_units=(forgejo-runner-docker.service forgejo-runner-podman.service)
prune_units=(forgejo-runner-cache-prune.service forgejo-runner-cache-pressure-prune.service)

skip() {
  printf 'skipped reason=%s\n' "$*"
  exit 0
}
fail() {
  printf 'failed step=%s\n' "$*" >&2
  exit 1
}

for value in "$settle_seconds" "$stop_timeout_seconds" "$start_timeout_seconds"; do
  [[ $value =~ ^[0-9]+$ ]] || exit 1
done
IFS=$' \t\n' read -r -d '' -a runner_units <<<"$runner_units_text" || true
((${#runner_units[@]} > 1)) || exit 1
[[ ${runner_units[0]} == forgejo-actions-runner.service &&
  ${runner_units[1]} == forgejo-podman-runner.service ]] || exit 1
for unit in "${runner_units[@]}"; do
  [[ $unit =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || exit 1
done

[[ -e $fence || -L $fence ]] || skip no_fence
[[ -d $state_dir && ! -L $state_dir && $(stat -c '%u:%a' -- "$state_dir") == "$EUID:700" ]] ||
  fail state_directory
[[ -d $fence && ! -L $fence && -f $fence/owner && ! -L $fence/owner ]] || fail fence_untrusted
owner=$(cat "$fence/owner") || fail fence_untrusted
# Manual Docker volume mode has an operator present, who keeps its recovery.
[[ $owner != cleanup-v3\ * ]] || skip manual_docker_fence
[[ $owner =~ ^cleanup-v2\ [1-9][0-9]*\ [1-9][0-9]*\ [0-9]+\ (DELETE|POST)\ /[^[:space:]]+$ ]] ||
  fail fence_format

# The newest change to the fence or its files, including a late response.
newest=0
shopt -s nullglob dotglob
for path in "$fence" "$fence"/*; do
  [[ ! -L $path ]] || fail fence_untrusted
  changed=$(stat -c '%Y' -- "$path") || fail fence_untrusted
  ((changed <= newest)) || newest=$changed
done
shopt -u nullglob dotglob
age=$(($(date +%s) - newest))
((age >= settle_seconds)) || skip "settling age_seconds=$age"

# The recovery repeats all of this under the lifecycle lock. These read-only
# checks only avoid stopping the APIs when the recovery would refuse anyway or
# when the stop would not be graceful.
for marker in owned pending teardown-required drain-pending resume-pending drain-disowned; do
  [[ ! -e $state_dir/$marker && ! -L $state_dir/$marker ]] || skip "transition_marker marker=$marker"
  for unit in "${runner_units[@]:1}"; do
    [[ ! -e $state_dir/runners/$unit/$marker && ! -L $state_dir/runners/$unit/$marker ]] ||
      skip "transition_marker marker=$marker"
  done
done
for unit in "${runner_units[@]}"; do
  metadata=$(timeout -k 2s 5s "$systemctl_bin" show --property=ActiveState --property=SubState \
    --property=MainPID --property=ControlPID --property=Job "$unit") || skip "runner_unreadable unit=$unit"
  active=unset sub=unset main=unset control=unset job=unset
  while IFS='=' read -r key value; do
    case $key in
      ActiveState) active=$value ;;
      SubState) sub=$value ;;
      MainPID) main=$value ;;
      ControlPID) control=$value ;;
      Job) job=$value ;;
    esac
  done <<<"$metadata"
  # systemctl renders the absence of a pending job as an empty Job= field.
  [[ $main == 0 && $control == 0 && -z $job ]] || skip "runner_active unit=$unit"
  case $active:$sub in
    inactive:dead | failed:failed) ;;
    *) skip "runner_active unit=$unit" ;;
  esac
done

# The cache prunes require the lifecycle boundary that stops with the APIs.
for unit in "${prune_units[@]}"; do
  metadata=$(timeout -k 2s 5s "$systemctl_bin" show --property=ActiveState --property=Job "$unit") ||
    skip "prune_unreadable unit=$unit"
  [[ $'\n'$metadata$'\n' == *$'\n'Job=$'\n'* &&
    ($'\n'$metadata$'\n' == *$'\n'ActiveState=inactive$'\n'* ||
    $'\n'$metadata$'\n' == *$'\n'ActiveState=failed$'\n'*) ]] || skip "prune_active unit=$unit"
done
# Checked last, as close to the stop as possible: the stop is graceful only for
# an unfrozen aggregate under an active guard. A freeze in between turns it
# into the lifecycle's forced teardown, which needs the operator.
[[ $(timeout -k 2s 5s "$systemctl_bin" show --property=FreezerState --value forgejobuilds.slice) == running ]] ||
  skip aggregate_frozen
timeout -k 2s 5s "$systemctl_bin" is-active --quiet forgejo-runner-io-pressure-guard.service ||
  skip guard_inactive

# Stopping both APIs ends any server-side work still running in their cgroups;
# the fence keeps them from starting again until the recovery has cleared it.
printf 'stopping_apis fence_age_seconds=%s owner=%s\n' "$age" "$owner"
timeout -k 5s "${stop_timeout_seconds}s" "$systemctl_bin" stop "${api_units[@]}" || fail api_stop
# A refusal leaves the fence, and therefore both stopped APIs, for the next run
# or the operator.
"$recover_bin" || fail recovery_refused
timeout -k 5s "${start_timeout_seconds}s" "$systemctl_bin" start "${api_units[@]}" || fail api_start
# A start that its ExecCondition skips need not fail the systemctl call.
for unit in "${api_units[@]}"; do
  timeout -k 2s 5s "$systemctl_bin" is-active --quiet "$unit" || fail "api_start unit=$unit"
done
printf 'recovered owner=%s\n' "$owner"
