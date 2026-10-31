#!/usr/bin/env bash
set -euo pipefail

# Resets the dedicated Podman CI store offline (ADR-0105). While every runner
# is idle or held by its owner, stop the running runners and both APIs, then
# under the lifecycle lock rename the store aside. The rename is the only
# exclusive mutation and cannot outlive this process, so no fence is needed.
# The renamed store is garbage that no API uses; it is deleted afterwards at
# the lowest priority, and whatever is left is deleted by a later run.
#
# `podman-store-reset restart` is the unit's ExecStopPost: it starts the units
# recorded before the first stop, so a failed or killed run does not leave them
# stopped. A runner whose start gate refuses that start is handed to the
# pressure guard, which resumes it once its own conditions allow.

state_dir=${STATE_DIR:-/run/forgejo-runner-aggregate-pressure}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
curl_bin=${CURL_BIN:-curl}
df_bin=${DF_BIN:-df}
jq_bin=${JQ_BIN:-jq}
remove_bin=${REMOVE_BIN:-rm}
mountinfo_file=${MOUNTINFO_FILE:-/proc/self/mountinfo}
cgroup_root=${CGROUP_ROOT:-/sys/fs/cgroup}
docker_socket=${DOCKER_SOCKET:-/run/forgejo-docker/docker.sock}
podman_socket=${PODMAN_SOCKET:-/run/forgejo-podman/podman.sock}
store_path=${STORE_PATH:-/var/lib/forgejo-podman/storage}
restart_file=${RESTART_FILE:-/run/forgejo-podman-store-reset/restart}
# The time of the last reset, kept where the API user cannot write.
stamp=${STAMP_FILE:-/var/lib/forgejo-podman-store-reset/reset-at}
trigger_used_percent=${TRIGGER_USED_PERCENT:-70}
max_age_seconds=${MAX_AGE_SECONDS:-604800}
# A full filesystem whose data is mostly not the store must not reset an
# already fresh store on every run.
min_age_seconds=${MIN_AGE_SECONDS:-21600}
pressure_file=${PRESSURE_FILE:-/proc/pressure/io}
io_pressure_threshold=${IO_PRESSURE_THRESHOLD_HUNDREDTHS:-500}
# A runner that admitted a job just before its stop finishes it first: the
# runner's shutdown waits up to its job timeout of one hour.
runner_stop_timeout=${RUNNER_STOP_TIMEOUT_SECONDS:-3700}
trash_seconds=${TRASH_SECONDS:-1800}
poll_seconds=${POLL_SECONDS:-2}
runner_units_text=${RUNNER_UNITS:-}
# shellcheck disable=SC1090
source "${GAME_HELPER_FILE:-$(dirname "${BASH_SOURCE[0]}")/game-admission.sh}"

api_units=(forgejo-runner-docker.service forgejo-runner-podman.service)
prune_units=(forgejo-runner-cache-prune.service forgejo-runner-cache-pressure-prune.service)
store_parent=${store_path%/*}
store_name=${store_path##*/}
trash_prefix=$store_parent/.$store_name.trash.
# Left by the cleanup this replaced (ADR-0083). Its store is reset at once.
legacy_fence=$state_dir/cleanup-in-flight

skip() {
  printf 'skipped reason=%s\n' "$*"
  exit 0
}
fail() {
  printf 'failed step=%s\n' "$*" >&2
  exit 1
}
valid_unit() { [[ $1 =~ ^[A-Za-z0-9_.@-]+\.service$ ]]; }

umask 077
for value in "$max_age_seconds" "$min_age_seconds" "$runner_stop_timeout" "$trash_seconds" "$poll_seconds" "$io_pressure_threshold"; do
  [[ $value =~ ^[0-9]+$ ]] || exit 1
done
[[ $trigger_used_percent =~ ^[1-9][0-9]?$ ]] || exit 1
[[ $store_path == /*/* && $store_name =~ ^[A-Za-z0-9_.-]+$ ]] || exit 1
IFS=$' \t\n' read -r -d '' -a runner_units <<<"$runner_units_text" || true
((${#runner_units[@]} > 1)) || exit 1
[[ ${runner_units[0]} == forgejo-actions-runner.service &&
  ${runner_units[1]} == forgejo-podman-runner.service ]] || exit 1
for unit in "${runner_units[@]}"; do
  valid_unit "$unit" || exit 1
done

# Starts the given APIs and runners, then hands every runner its start gate
# refused to the guard's resume path through a hold marker: a skipped start
# does not fail `systemctl start`, and nothing else would start it again.
start_again() {
  local status=0 unit runner directory active
  timeout -k 5s 300s "$systemctl_bin" start "$@" || status=1
  for unit in "$@"; do
    directory=
    if [[ $unit == "${runner_units[0]}" ]]; then
      directory=$state_dir
    else
      for runner in "${runner_units[@]:1}"; do
        [[ $unit != "$runner" ]] || directory=$state_dir/runners/$unit
      done
    fi
    [[ -n $directory ]] || continue
    active=$(timeout -k 2s 10s "$systemctl_bin" show --property=ActiveState --value "$unit") || active=unknown
    case $active in
      active | activating | reloading) ;;
      inactive)
        # The guard resumes only an inactive runner.
        if [[ -d $directory && ! -L $directory ]]; then
          : >"$directory/reset-start-skipped" || status=1
          printf 'handed_to_guard unit=%s state=%s\n' "$unit" "$active"
        else
          status=1
        fi
        ;;
      *)
        printf 'start_failed unit=%s state=%s\n' "$unit" "$active" >&2
        status=1
        ;;
    esac
  done
  return "$status"
}
if [[ ${1:-} == restart ]]; then
  [[ -f $restart_file && ! -L $restart_file ]] || exit 0
  units=()
  while IFS= read -r unit; do
    valid_unit "$unit" || fail "restart_list unit=$unit"
    units+=("$unit")
  done <"$restart_file"
  status=0
  if ((${#units[@]} > 0)); then
    start_again "${units[@]}" || status=$?
  fi
  rm -f -- "$restart_file"
  printf 'restarted units=%s\n' "${units[*]}"
  exit "$status"
fi
[[ -d $state_dir && ! -L $state_dir && $(stat -c '%u:%a' -- "$state_dir") == "$EUID:700" ]] ||
  skip aggregate_state_missing
[[ -d $store_parent && ! -L $store_parent ]] || skip store_parent_missing

# Sets io_pressure to the host's full avg10 stall in hundredths of a percent
# and succeeds only for a readable sample at or below the guard's resume
# threshold. An unreadable sample never permits work.
io_pressure_low() {
  io_pressure=$(awk '
    $1 == "full" {
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^avg10=[0-9]+([.][0-9]+)?$/) {
          split($i, part, "="); printf "%.0f\n", part[2] * 100; found = 1
        }
      }
    }
    END { if (!found) exit 1 }
  ' "$pressure_file" 2>/dev/null) || io_pressure=unknown
  [[ $io_pressure =~ ^[0-9]+$ ]] && ((io_pressure <= io_pressure_threshold))
}
# Sets hold_reason and succeeds while a game, an uncertain game scan or I/O
# pressure asks this unit to stay out of the way.
host_busy() {
  local status=0
  game_admission_status || status=$?
  if ((status != 1)); then
    # shellcheck disable=SC2154 # game_admission_status sets game_reason.
    hold_reason="game reason=$game_reason"
    return 0
  fi
  if ! io_pressure_low; then
    hold_reason="io_pressure full_avg10_hundredths=$io_pressure"
    return 0
  fi
  return 1
}

# Removes one tree in the background at the lowest CPU and I/O priority and
# stops it as soon as a game, pressure or the deadline asks for that. A killed
# removal leaves only garbage behind.
remove_bounded() {
  local pid next_check=0
  nice -n 19 ionice -c 3 chrt --idle 0 "$remove_bin" -rf --one-file-system -- "$1" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if ((SECONDS >= next_check)); then
      if host_busy || { ((SECONDS >= trash_deadline)) && hold_reason=deadline; }; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" || true
        printf 'trash_left reason=%s\n' "$hold_reason"
        return 1
      fi
      next_check=$((SECONDS + poll_seconds))
    fi
    sleep 0.1
  done
  wait "$pid" || printf 'trash_skipped reason=not_removed path=%s\n' "$1"
}
# Deletes every renamed store. The store's directory belongs to the API user,
# who can also create entries with the trash name. Anything that is not a
# directory is unlinked without being followed or opened. A directory is
# opened through "/." so a FIFO swapped in fails instead of blocking. A
# symlink swapped in still resolves through "/.": the identity check after the
# open (no symlink at the path, the same device and inode as the descriptor,
# the store's device) is what keeps the removal on the trash, so it must stay.
# The directory is then emptied through that descriptor. An entry that fails
# these checks or cannot be removed is reported and skipped, never followed,
# and does not hold a reset. Fails only when a game, pressure or the deadline
# stopped the deletion.
delete_trash() {
  local trash entry
  local -a trashes entries
  trash_deadline=$((SECONDS + trash_seconds))
  shopt -s nullglob
  trashes=("$trash_prefix"*)
  shopt -u nullglob
  for trash in "${trashes[@]}"; do
    if [[ -L $trash || ! -d $trash ]]; then
      rm -f -- "$trash" 2>/dev/null || true
      printf 'trash_skipped reason=not_a_directory path=%s\n' "$trash"
      continue
    fi
    # The group keeps the stderr redirection to this open.
    if ! { exec 8<"$trash/."; } 2>/dev/null; then
      printf 'trash_skipped reason=unopenable path=%s\n' "$trash"
      continue
    fi
    if ! [[ ! -L $trash && -d /proc/self/fd/8 &&
      $(stat -Lc '%d:%i' /proc/self/fd/8) == "$(stat -c '%d:%i' -- "$trash")" &&
      $(stat -Lc '%d' /proc/self/fd/8) == "$(stat -c '%d' -- "$store_parent")" ]]; then
      exec 8<&-
      printf 'trash_skipped reason=untrusted path=%s\n' "$trash"
      continue
    fi
    shopt -s nullglob dotglob
    entries=(/proc/self/fd/8/*)
    shopt -u nullglob dotglob
    for entry in "${entries[@]}"; do
      remove_bounded "$entry" || {
        exec 8<&-
        return 1
      }
    done
    exec 8<&-
    rmdir -- "$trash" 2>/dev/null || printf 'trash_skipped reason=not_removed path=%s\n' "$trash"
  done
}

# 1. Leftover trash first. It needs no stop, and a store reset waits for it so
#    that filesystem use measures the store rather than its garbage.
started=$SECONDS
shopt -s nullglob
leftover=("$trash_prefix"*)
shopt -u nullglob
if ((${#leftover[@]} > 0)); then
  delete_trash || skip trash_left
  printf 'trash_deleted seconds=%s\n' $((SECONDS - started))
fi

# 2. Is a reset due?
now=$(date +%s)
if [[ ! -e $stamp ]]; then
  # The first run only starts the age clock.
  printf '%s\n' "$now" >"$stamp"
fi
[[ -f $stamp && ! -L $stamp ]] || fail stamp_untrusted
age=$((now - $(stat -c '%Y' -- "$stamp")))
sample=$("$df_bin" --block-size=1 --output=size,avail "$store_parent" | awk 'NR == 2 { print $1, $2 }') ||
  skip store_unreadable
read -r total available <<<"$sample"
[[ $total =~ ^[1-9][0-9]*$ && $available =~ ^[0-9]+$ ]] || skip store_unreadable
used_percent=$(((total - available) * 100 / total))
if [[ -e $legacy_fence || -L $legacy_fence ]]; then
  due=legacy_fence
elif ((age >= max_age_seconds)); then
  due=store_age
elif ((used_percent >= trigger_used_percent && age >= min_age_seconds)); then
  due=store_use
else
  skip "not_due used_percent=$used_percent age_seconds=$age"
fi

# 3. Host, guard and aggregate. A frozen aggregate would turn the API stop
#    into the lifecycle's forced teardown.
if host_busy; then skip "$hold_reason"; fi
query() { timeout -k 2s 10s "$systemctl_bin" "$@"; }
query is-active --quiet forgejo-runner-io-pressure-guard.service || skip guard_inactive
aggregate_running() {
  [[ $(query show --property=FreezerState --value forgejobuilds.slice) == running ]]
}
aggregate_running || skip aggregate_frozen
# The guard's registry decides every start gate. After a switch that changed
# the runner list, the preserved registry keeps the old list until a reboot
# (a restarted guard refuses the changed list), and the gates refuse every
# start: a reset must not stop what it cannot start again.
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
for marker in owned pending teardown-required; do
  [[ ! -e $state_dir/$marker && ! -L $state_dir/$marker ]] || skip "guard_marker marker=$marker"
done
for unit in "${runner_units[@]}"; do
  directory=$state_dir/runners/$unit
  [[ $unit != "${runner_units[0]}" ]] || directory=$state_dir
  for marker in drain-pending resume-pending resume-queued drain-disowned; do
    [[ ! -e $directory/$marker && ! -L $directory/$marker ]] || skip "guard_marker marker=$marker unit=$unit"
  done
done

# Reads ActiveState, SubState, MainPID, ControlPID and Job of a unit.
unit_state() {
  local metadata key value
  active=unset sub=unset main=unset control=unset job=unset
  metadata=$(query show --property=ActiveState --property=SubState --property=MainPID \
    --property=ControlPID --property=Job "$1") || return 1
  while IFS='=' read -r key value; do
    case $key in
      ActiveState) active=$value ;;
      SubState) sub=$value ;;
      MainPID) main=$value ;;
      ControlPID) control=$value ;;
      Job) job=$value ;;
    esac
  done <<<"$metadata"
}
for unit in "${prune_units[@]}"; do
  unit_state "$unit" || skip "prune_unreadable unit=$unit"
  [[ -z $job && ($active == inactive || $active == failed) ]] || skip "prune_active unit=$unit"
done
for unit in "${api_units[@]}"; do
  unit_state "$unit" || skip "api_unreadable unit=$unit"
  # systemctl renders the absence of a pending job as an empty Job= field.
  [[ -z $job && $active == active ]] || skip "api_inactive unit=$unit"
done
# A running runner is stopped and started again; a stopped one belongs to
# whoever stopped it (the guard, a start gate or the operator) and stays so.
to_stop=()
for unit in "${runner_units[@]}"; do
  unit_state "$unit" || skip "runner_unreadable unit=$unit"
  [[ -z $job ]] || skip "runner_job unit=$unit"
  case $active:$sub in
    active:running) to_stop+=("$unit") ;;
    inactive:dead | failed:failed) ;;
    *) skip "runner_transition unit=$unit state=$active:$sub" ;;
  esac
done
# Idleness only keeps the stop short: a job admitted after this check still
# finishes, because the runner's shutdown waits for it.
for socket in "$docker_socket" "$podman_socket"; do
  containers=$("$curl_bin" --silent --show-error --fail --max-time 10 --connect-timeout 2 \
    --unix-socket "$socket" http://localhost/containers/json) || skip "engine_api_unavailable socket=$socket"
  status=0
  "$jq_bin" -e 'if type != "array" then error("not a container list") else
    any(.[]; (.Names // []) | any(.[]; type == "string" and
      (ltrimstr("/") | startswith("FORGEJO-ACTIONS-TASK-")))) end' <<<"$containers" >/dev/null 2>&1 ||
    status=$?
  ((status != 0)) || skip "job_running socket=$socket"
  ((status == 1)) || skip "engine_api_invalid socket=$socket"
done

# 4. Stop. From here on the unit's ExecStopPost starts these units again.
printf '%s\n' "${api_units[@]}" "${to_stop[@]}" >"$restart_file.new"
mv -f -- "$restart_file.new" "$restart_file"
printf 'stopping due=%s used_percent=%s age_seconds=%s runners=%s\n' \
  "$due" "$used_percent" "$age" "${to_stop[*]:-none}"
stop_started=$SECONDS
if ((${#to_stop[@]} > 0)); then
  timeout -k 5s "${runner_stop_timeout}s" "$systemctl_bin" stop "${to_stop[@]}" || fail runner_stop
fi
# Checked again right before the stop that the lifecycle teardown observes.
aggregate_running || skip aggregate_frozen
query is-active --quiet forgejo-runner-io-pressure-guard.service || skip guard_inactive
# A runner started meanwhile (a standby controller or a guard resume) may have
# admitted a job, which the API stop would then wait for.
for unit in "${runner_units[@]}"; do
  unit_state "$unit" || skip "runner_unreadable unit=$unit"
  [[ -z $job && ($active == inactive || $active == failed) ]] || skip "runner_started unit=$unit"
done
timeout -k 5s 300s "$systemctl_bin" stop "${api_units[@]}" || fail api_stop

# 5. Rename under the lifecycle lock. Every runner and API start gate takes the
#    same lock first, so none can start between this proof and the rename.
exec 9>"$state_dir/lifecycle.lock"
flock -w 60 -x 9 || skip lifecycle_locked
for unit in "${runner_units[@]}" "${api_units[@]}"; do
  unit_state "$unit" || skip "unit_unreadable unit=$unit"
  [[ -z $job && $main == 0 && $control == 0 ]] || skip "unit_not_stopped unit=$unit"
  case $active:$sub in
    inactive:dead | failed:failed) ;;
    *) skip "unit_not_stopped unit=$unit" ;;
  esac
done
for unit in "${api_units[@]}"; do
  events=$cgroup_root/forgejobuilds.slice/$unit/cgroup.events
  if [[ -e $events ]]; then
    [[ $(awk '$1 == "populated" { print $2 }' "$events") == 0 ]] || skip "api_cgroup_populated unit=$unit"
  fi
done
# Rename a directory inside the store's filesystem, never a mount itself.
while read -r _ _ _ _ mount_point _; do
  [[ $mount_point != "$store_path" && $mount_point != "$store_path"/* ]] ||
    skip "store_mounted path=$mount_point"
done <"$mountinfo_file"
trash=$trash_prefix$now
if [[ -e $store_path || -L $store_path ]]; then
  [[ -d $store_path && ! -L $store_path && ! -e $trash ]] || fail store_untrusted
  # Same device, so mv is one rename(2) and never a copy.
  [[ $(stat -c '%d' -- "$store_path") == "$(stat -c '%d' -- "$store_parent")" ]] || fail store_device
  mv -T -- "$store_path" "$trash" || fail rename
fi
printf '%s\n' "$now" >"$stamp"
# Commit the rename and the stamp together, so a crash cannot keep the old
# store while the age clock restarts.
sync -- "$store_parent" "$stamp" || fail sync
if [[ -e $legacy_fence || -L $legacy_fence ]]; then
  "$remove_bin" -rf -- "$legacy_fence" || fail legacy_fence
fi
exec 9>&-

# 6. Start again at once; the start gates still decide each start.
start_again "${api_units[@]}" "${to_stop[@]}" || fail start
rm -f -- "$restart_file"
printf 'reset due=%s stopped_seconds=%s\n' "$due" $((SECONDS - stop_started))

# 7. The old store is garbage now.
started=$SECONDS
if delete_trash; then
  printf 'trash_deleted seconds=%s\n' $((SECONDS - started))
fi
