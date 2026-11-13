#!/usr/bin/env bash
set -euo pipefail

# Resets the dedicated Podman CI store offline (ADR-0105). While every runner
# is idle or held by its owner, stop the running runners and both APIs, then
# under the start lock rename the store aside. The rename is the only
# exclusive mutation and cannot outlive this process, so no fence is needed.
# The renamed store is garbage that no API uses; it is deleted afterwards at
# the lowest priority, and whatever is left is deleted by a later run.
#
# `podman-store-reset restart` is the unit's ExecStopPost: it starts the units
# recorded before the first stop, so a failed or killed run does not leave them
# stopped. A runner whose start gate refuses that start keeps the gate's `held`
# marker, and the runner hold starts it once its hold reason ends (ADR-0106).

state_dir=${STATE_DIR:-/run/forgejo-runner-hold}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
journalctl_bin=${JOURNALCTL_BIN:-journalctl}
curl_bin=${CURL_BIN:-curl}
df_bin=${DF_BIN:-df}
jq_bin=${JQ_BIN:-jq}
remove_bin=${REMOVE_BIN:-rm}
mountinfo_file=${MOUNTINFO_FILE:-/proc/self/mountinfo}
cgroup_root=${CGROUP_ROOT:-/sys/fs/cgroup}
docker_socket=${DOCKER_SOCKET:-/run/forgejo-docker/docker.sock}
podman_socket=${PODMAN_SOCKET:-/run/forgejo-podman/podman.sock}
store_path=${STORE_PATH:-/var/lib/forgejo-podman/storage}
# The graphroot in RAM scratch, when the store's images and containers are
# split (#1027): it holds the containers, which reference image layers in
# the store, so the two are always reset together. Volumes are in RAM too, on
# the ext4 filesystem on zram mounted at VOLUME_MOUNT, which the API's start
# makes afresh, or else on disk beside the store (ADR-0108); the API's start
# moves those an earlier API left on disk aside under the store's trash name,
# which this deletes.
scratch_store=${SCRATCH_STORE:-}
volume_mount=${VOLUME_MOUNT:-}
# The API start that made the volume filesystem writes its systemd
# invocation ID here: an API started before a deploy that moved its volumes
# to RAM still uses the disk, and its filesystem is not checked.
volume_stamp=${VOLUME_STAMP:-/run/forgejo-podman-volumes.started}
ext4_sysfs=${EXT4_SYSFS:-/sys/fs/ext4}
zram_sysfs=${ZRAM_SYSFS:-/sys/block}
restart_file=${RESTART_FILE:-/run/forgejo-podman-store-reset/restart}
# The time of the last reset, kept where the API user cannot write.
stamp=${STAMP_FILE:-/var/lib/forgejo-podman-store-reset/reset-at}
trigger_used_percent=${TRIGGER_USED_PERCENT:-70}
# Leftover containers and volumes in the RAM scratch, or in the volume
# filesystem, reset them at this use of either, so the largest job the host
# takes still fits beside them. The volume filesystem's use is the larger of
# its byte and inode use.
scratch_trigger_percent=${SCRATCH_TRIGGER_PERCENT:-70}
# A scratch or volume filesystem this full fails every job's setup, so each
# failing job would renew the quiet interval and keep the reset away for
# good.
scratch_full_percent=${SCRATCH_FULL_PERCENT:-90}
# The runner pause of nix-packages ADR-0017: a runner whose pause file exists
# takes no new job and reports "paused tasks=<running>" as its status text.
pause_dir=${PAUSE_DIR:-/run/nixfleet-runners/paused}
pause_wait_seconds=${PAUSE_WAIT_SECONDS:-600}
# The pauses this reset set, which its ExecStopPost removes if it is killed.
pause_record=${PAUSE_RECORD:-/run/forgejo-podman-store-reset/paused}
max_age_seconds=${MAX_AGE_SECONDS:-604800}
# A full filesystem whose data is mostly not the store must not reset an
# already fresh store on every run.
min_age_seconds=${MIN_AGE_SECONDS:-21600}
pressure_file=${PRESSURE_FILE:-/proc/pressure/io}
io_pressure_threshold=${IO_PRESSURE_THRESHOLD_HUNDREDTHS:-500}
# A runner stop waits for its running jobs up to the runner's shutdown timeout
# (one hour, or two minutes on a game host) and then cancels them. The idle
# check below keeps a reset from stopping a runner that has a job.
runner_stop_timeout=${RUNNER_STOP_TIMEOUT_SECONDS:-3700}
# A runner must have started no job for this long: a job that is still
# pulling its image or setting up has no task container yet.
quiet_seconds=${QUIET_SECONDS:-900}
trash_seconds=${TRASH_SECONDS:-1800}
poll_seconds=${POLL_SECONDS:-2}
runner_units_text=${RUNNER_UNITS:-}
hold_unit=${HOLD_UNIT:-forgejo-runner-hold.service}
game_enabled=${GAME_ENABLED:-0}
game_file=${GAME_FILE:-/run/game-signal/active}
game_unit=${GAME_UNIT:-game-signal.service}

api_units=(forgejo-runner-docker.service forgejo-runner-podman.service)
prune_units=(forgejo-runner-cache-prune.service forgejo-runner-cache-pressure-prune.service)
store_parent=${store_path%/*}
store_name=${store_path##*/}
trash_prefix=$store_parent/.$store_name.trash.
scratch_parent=${scratch_store%/*}
scratch_trash_prefix=$scratch_parent/.${scratch_store##*/}.trash.
# Left by the cleanup this replaced (ADR-0083). Its store is reset at once.
legacy_fence=${LEGACY_FENCE:-/run/forgejo-runner-aggregate-pressure/cleanup-in-flight}

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
for value in "$max_age_seconds" "$min_age_seconds" "$runner_stop_timeout" "$quiet_seconds" "$trash_seconds" "$poll_seconds" "$io_pressure_threshold" "$pause_wait_seconds"; do
  [[ $value =~ ^[0-9]+$ ]] || exit 1
done
[[ $trigger_used_percent =~ ^[1-9][0-9]?$ ]] || exit 1
[[ $scratch_trigger_percent =~ ^[1-9][0-9]?$ && $scratch_full_percent =~ ^[1-9][0-9]?$ ]] || exit 1
[[ $game_enabled == 0 || $game_enabled == 1 ]] || exit 1
[[ $store_path == /*/* && $store_name =~ ^[A-Za-z0-9_.-]+$ ]] || exit 1
if [[ -n $scratch_store ]]; then
  [[ $scratch_store == /*/* && ${scratch_store##*/} =~ ^[A-Za-z0-9_.-]+$ ]] || exit 1
  [[ $scratch_parent != "$store_parent" ]] || exit 1
  [[ -z $volume_mount || ($volume_mount == /*/* && $volume_mount != */) ]] || exit 1
  [[ -z $volume_mount || $volume_stamp == /*/* ]] || exit 1
else
  [[ -z $volume_mount ]] || exit 1
fi
IFS=$' \t\n' read -r -d '' -a runner_units <<<"$runner_units_text" || true
((${#runner_units[@]} > 1)) || exit 1
[[ ${runner_units[0]} == forgejo-actions-runner.service &&
  ${runner_units[1]} == forgejo-podman-runner.service ]] || exit 1
# The Podman pool runners: the first, then a second slot.
pool_units=("${runner_units[@]:1}")
((${#pool_units[@]} == 1)) ||
  [[ ${#pool_units[@]} == 2 && ${pool_units[1]} == forgejo-podman-runner-2.service ]] || exit 1
for unit in "${runner_units[@]}" "$hold_unit" "$game_unit"; do
  valid_unit "$unit" || exit 1
done
is_runner() {
  local runner
  for runner in "${runner_units[@]}"; do
    [[ $1 != "$runner" ]] || return 0
  done
  return 1
}

# Starts the given APIs and runners. A runner whose start gate refused the
# start is inactive with the gate's `held` marker, which hands it to the
# runner hold: a skipped start does not fail `systemctl start`.
start_again() {
  local status=0 unit active
  timeout -k 5s 300s "$systemctl_bin" start "$@" || status=1
  for unit in "$@"; do
    is_runner "$unit" || continue
    active=$(timeout -k 2s 10s "$systemctl_bin" show --property=ActiveState --value "$unit") || active=unknown
    case $active in
      active | activating | reloading) ;;
      inactive)
        if [[ -e $state_dir/runners/$unit/held ]]; then
          printf 'handed_to_hold unit=%s state=%s\n' "$unit" "$active"
        else
          printf 'start_skipped unit=%s state=%s\n' "$unit" "$active" >&2
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
# Removes the pauses this reset set, so no runner starts paused.
unpause() {
  local unit
  [[ -f $pause_record && ! -L $pause_record ]] || return 0
  while IFS= read -r unit; do
    valid_unit "$unit" && rm -f -- "$pause_dir/$unit"
  done <"$pause_record"
  rm -f -- "$pause_record"
}
if [[ ${1:-} == restart ]]; then
  unpause
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
  skip hold_state_missing
[[ -d $store_parent && ! -L $store_parent ]] || skip store_parent_missing
if [[ -n $scratch_store ]]; then
  [[ -d $scratch_parent && ! -L $scratch_parent ]] || skip scratch_parent_missing
fi

# Sets io_pressure to the host's full avg10 stall in hundredths of a percent
# and succeeds only for a readable sample at or below the reset's
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
# Sets hold_reason and succeeds while a game, an unavailable game signal or
# I/O pressure asks this unit to stay out of the way.
host_busy() {
  if ((game_enabled == 1)); then
    if ! timeout -k 2s 10s "$systemctl_bin" is-active --quiet "$game_unit"; then
      hold_reason=game_signal_unavailable
      return 0
    fi
    if [[ -e $game_file ]]; then
      hold_reason=game
      return 0
    fi
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
delete_trash_in() {
  local parent=$1 prefix=$2 trash entry
  local -a trashes entries
  shopt -s nullglob
  trashes=("$prefix"*)
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
      $(stat -Lc '%d' /proc/self/fd/8) == "$(stat -c '%d' -- "$parent")" ]]; then
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
# Scratch first: its trash is RAM that the next jobs need.
delete_trash() {
  trash_deadline=$((SECONDS + trash_seconds))
  if [[ -n $scratch_store ]]; then
    delete_trash_in "$scratch_parent" "$scratch_trash_prefix" || return 1
  fi
  delete_trash_in "$store_parent" "$trash_prefix"
}

# 1. Leftover trash first. It needs no stop, and a store reset waits for it so
#    that filesystem use measures the store rather than its garbage. A reset
#    of the scratch alone touches no disk, so it does not wait for the disk
#    trash: deleting a large old store can take longer than one run.
started=$SECONDS
trash_left=0
shopt -s nullglob
leftover=("$trash_prefix"*)
[[ -z $scratch_store ]] || leftover+=("$scratch_trash_prefix"*)
shopt -u nullglob
if ((${#leftover[@]} > 0)); then
  if delete_trash; then
    printf 'trash_deleted seconds=%s\n' $((SECONDS - started))
  else
    trash_left=1
  fi
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
scratch_percent=none
volume_percent=none
volume_state=
scratch_note=
leftover_note=
leftovers=none
if [[ -n $scratch_store ]]; then
  sample=$("$df_bin" --block-size=1 --output=size,avail "$scratch_parent" | awk 'NR == 2 { print $1, $2 }') ||
    skip scratch_unreadable
  read -r total available <<<"$sample"
  [[ $total =~ ^[1-9][0-9]*$ && $available =~ ^[0-9]+$ ]] || skip scratch_unreadable
  scratch_percent=$(((total - available) * 100 / total))
  scratch_note=" scratch_percent=$scratch_percent"
  # Containers that no running job owns: those a job started through the API
  # and left behind, when it was cancelled before its cleanup ran or its
  # cleanup failed. A leftover can keep running and holding memory while
  # adding little to the scratch; any one of them makes a scratch reset due.
  # An unreadable list triggers nothing.
  leftovers=$("$curl_bin" --silent --show-error --fail --max-time 10 --connect-timeout 2 \
    --unix-socket "$podman_socket" 'http://localhost/containers/json?all=true' 2>/dev/null |
    "$jq_bin" -e 'if type != "array" then error("not a container list") else
      [.[] | select(((.State == "running") and ((.Names // []) | any(.[]; type == "string" and
        (ltrimstr("/") | startswith("FORGEJO-ACTIONS-TASK-"))))) | not)] | length end' 2>/dev/null) ||
    leftovers=unknown
  [[ $leftovers =~ ^[0-9]+$ ]] || leftovers=unknown
  leftover_note=" leftover_containers=$leftovers"
  if [[ -n $volume_mount ]]; then
    # The volume filesystem, when the running API made it. It is unusable,
    # and every job that creates a volume fails, after an ext4 error, when
    # read-only, not mounted or covered by another filesystem; only the
    # API's next start makes it again, except under another filesystem,
    # where that start refuses and an operator must unmount it. Under errors=remount-ro an ext4 error
    # stops all writes, but on the hosts' kernel (7.3.3 in the VM check)
    # mountinfo still shows the mount and the superblock rw, the superblock
    # with emergency_ro: the error count that ext4 keeps in its superblock,
    # zero on a fresh filesystem, shows it. A failed write of file data is
    # not an ext4 error and is not counted (ADR-0108).
    api_invocation=$(timeout -k 2s 10s "$systemctl_bin" show --property=InvocationID --value forgejo-runner-podman.service 2>/dev/null) ||
      api_invocation=
    volume_started=
    # read, not $(<file): an API start removes the file, and bash 5.2 exits
    # on a failed $(<file) under set -e.
    if [[ -f $volume_stamp && ! -L $volume_stamp ]]; then
      { read -r volume_started <"$volume_stamp"; } 2>/dev/null || volume_started=
    fi
    if [[ ! $api_invocation =~ ^[0-9a-f]{32}$ || $volume_started != "$api_invocation" ]]; then
      scratch_note+=" volumes=not_in_use"
    else
      # Mount options, filesystem type, source and superblock options.
      volume_fields=$(awk -v mount="$volume_mount" '$5 == mount {
          for (i = 7; i <= NF && $i != "-"; i++) {}
          fields = $6 " " $(i + 1) " " $(i + 2) " " $(i + 3)
        } END { print fields }' "$mountinfo_file") || skip volumes_unreadable
      read -r volume_options volume_type volume_source volume_super <<<"$volume_fields"
      volume_device=${volume_source#/dev/}
      if [[ -z $volume_options ]]; then
        volume_state=unmounted
      elif [[ $volume_type != ext4 || ! $volume_device =~ ^zram[0-9]+$ ]]; then
        volume_state=foreign
      elif [[ ,$volume_options, == *,ro,* || ,$volume_super, == *,ro,* ]]; then
        volume_state=read_only
      else
        # read, not $(<file): bash 5.2 exits on a failed $(<file) under set -e
        # even with || after it.
        { read -r volume_errors <"$ext4_sysfs/$volume_device/errors_count"; } 2>/dev/null ||
          skip volumes_unreadable
        [[ $volume_errors =~ ^[0-9]+$ ]] || skip volumes_unreadable
        if ((volume_errors > 0)); then
          volume_state=fs_error
        else
          # Bytes and inodes: a leftover volume of many small or empty
          # files can use up the inodes while few bytes are used, and then
          # every new volume fails with "No space left on device" as on a
          # full filesystem. The fuller of the two counts.
          sample=$("$df_bin" --block-size=1 --output=size,avail,itotal,iavail "$volume_mount" |
            awk 'NR == 2 { print $1, $2, $3, $4 }') || skip volumes_unreadable
          read -r total available inodes inodes_free <<<"$sample"
          [[ $total =~ ^[1-9][0-9]*$ && $available =~ ^[0-9]+$ &&
            $inodes =~ ^[1-9][0-9]*$ && $inodes_free =~ ^[0-9]+$ ]] || skip volumes_unreadable
          volume_percent=$(((total - available) * 100 / total))
          volume_inode_percent=$(((inodes - inodes_free) * 100 / inodes))
          scratch_note+=" volume_percent=$volume_percent volume_inode_percent=$volume_inode_percent"
          ((volume_inode_percent <= volume_percent)) || volume_percent=$volume_inode_percent
          # zsmalloc keeps partly used pages after frees until it compacts,
          # which the kernel does on its own only under memory pressure;
          # compacting here keeps the device's memory near what it stores.
          if [[ -w $zram_sysfs/$volume_device/compact ]]; then
            { echo 1 >"$zram_sysfs/$volume_device/compact"; } 2>/dev/null || true
          fi
        fi
      fi
    fi
    [[ -z $volume_state ]] || scratch_note+=" volume_state=$volume_state"
  fi
fi
if [[ -e $legacy_fence || -L $legacy_fence ]]; then
  due=legacy_fence
elif ((age >= max_age_seconds)); then
  due=store_age
elif ((used_percent >= trigger_used_percent && age >= min_age_seconds)); then
  due=store_use
elif [[ -n $volume_state ]]; then
  # The API's next start makes the volume filesystem again.
  due=volumes_unusable
elif [[ $scratch_percent != none ]] && ((scratch_percent >= scratch_trigger_percent)); then
  # Containers that jobs left behind fill the RAM scratch. A
  # reset always empties it, so it needs no minimum age.
  due=scratch_use
elif [[ $volume_percent != none ]] && ((volume_percent >= scratch_trigger_percent)); then
  # Volumes that jobs left behind fill the volume filesystem in RAM, its
  # bytes or its inodes, which the API's next start makes again.
  due=scratch_use
elif [[ $leftovers =~ ^[1-9][0-9]*$ ]]; then
  # The same reset of the scratch alone, at the next quiet check.
  due=leftover_containers
else
  skip "not_due used_percent=$used_percent$scratch_note age_seconds=$age$leftover_note"
fi
# A reset of the scratch alone keeps the images and the age clock.
scratch_only=0
case $due in scratch_use | volumes_unusable | leftover_containers) scratch_only=1 ;; esac
if ((trash_left == 1 && scratch_only == 0)); then skip trash_left; fi

# 3. Host and runner hold. The hold starts any runner whose start a gate
#    refuses, so it must run.
if host_busy; then skip "$hold_reason"; fi
query() { timeout -k 2s 10s "$systemctl_bin" "$@"; }
query is-active --quiet "$hold_unit" || skip hold_inactive
for unit in "${runner_units[@]}"; do
  [[ -d $state_dir/runners/$unit && ! -L $state_dir/runners/$unit ]] || skip "runner_state_missing unit=$unit"
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
# whoever stopped it (the runner hold, a start gate or the operator) and stays so.
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
# Succeeds while an engine at one of the given sockets runs a job container,
# and names the first such socket in job_socket.
job_containers() {
  local socket containers status
  for socket in "$@"; do
    containers=$("$curl_bin" --silent --show-error --fail --max-time 10 --connect-timeout 2 \
      --unix-socket "$socket" http://localhost/containers/json) || skip "engine_api_unavailable socket=$socket"
    status=0
    "$jq_bin" -e 'if type != "array" then error("not a container list") else
      any(.[]; (.Names // []) | any(.[]; type == "string" and
        (ltrimstr("/") | startswith("FORGEJO-ACTIONS-TASK-")))) end' <<<"$containers" >/dev/null 2>&1 ||
      status=$?
    if ((status == 0)); then
      job_socket=$socket
      return 0
    fi
    ((status == 1)) || skip "engine_api_invalid socket=$socket"
  done
  return 1
}
# Succeeds when the runner logged a job start within the quiet interval, or
# when its journal is unreadable. forgejo-runner logs every task it takes at
# info level as `task <id> repo is ...` (internal/app/run/runner.go).
recent_job() {
  local since lines
  since=$(($(date +%s) - quiet_seconds))
  lines=$("$journalctl_bin" --unit="$1" --since="@$since" --output=cat --no-pager --quiet 2>/dev/null) || return 0
  grep -Eq 'msg="task [0-9]+ repo is ' <<<"$lines"
}
# On a full scratch, whatever made the reset due, most new pool jobs fail and
# each would renew the quiet interval, so the reset might never run; a pool
# job that is still running would hold it the same way, check after check,
# while each new job fails. There the running Podman pool runners are paused
# instead: they take no new job, and the reset goes on only once each reports
# none running and the Podman API runs no job container, and again right
# before its stop. The Docker runner's jobs use their own store and keep both
# guards.
is_pool() {
  local unit
  for unit in "${pool_units[@]}"; do
    [[ $1 == "$unit" ]] && return 0
  done
  return 1
}
scratch_full=0
if [[ $scratch_percent != none ]] && ((scratch_percent >= scratch_full_percent)); then
  scratch_full=1
fi
# The volume filesystem's use counts its inodes too: with none left, every
# new volume fails as on a full filesystem.
if [[ -n $volume_state ]] || { [[ $volume_percent != none ]] && ((volume_percent >= scratch_full_percent)); }; then
  scratch_full=1
fi
pool_running=0
for unit in "${to_stop[@]}"; do
  if is_pool "$unit"; then pool_running=1; fi
done
# The reset never stops a runner with a job: the stop would cancel it once the
# runner's shutdown timeout passes. Both checks run again right before each
# stop; a job admitted between that check and the stop is the one window left.
# The Docker API is asked first, so a job there always skips.
drain_pool=0
if job_containers "$docker_socket" "$podman_socket"; then
  if ((scratch_full == 0 || pool_running == 0)) || [[ $job_socket != "$podman_socket" ]]; then
    skip "job_running socket=$job_socket"
  fi
  drain_pool=1
fi
for unit in "${to_stop[@]}"; do
  recent_job "$unit" || continue
  if ((scratch_full == 0)) || ! is_pool "$unit"; then skip "recent_job unit=$unit"; fi
  drain_pool=1
done
drain=()
if ((drain_pool == 1)); then
  for unit in "${to_stop[@]}"; do
    is_pool "$unit" || continue
    # A pause someone else set, such as a runner restart's, is theirs.
    [[ ! -e $pause_dir/$unit ]] || skip "runner_paused unit=$unit"
    drain+=("$unit")
  done
fi
quiet_needed() { ((drain_pool == 0)) || ! is_pool "$1"; }

# 4. Stop. From here on the unit's ExecStopPost starts these units again.
printf '%s\n' "${api_units[@]}" "${to_stop[@]}" >"$restart_file.new"
mv -f -- "$restart_file.new" "$restart_file"
printf 'stopping due=%s used_percent=%s%s age_seconds=%s%s runners=%s\n' \
  "$due" "$used_percent" "$scratch_note" "$age" "$leftover_note" "${to_stop[*]:-none}"
if ((drain_pool == 1)); then
  printf '%s\n' "${drain[@]}" >"$pause_record"
  install -d -m 0755 -- "$pause_dir"
  for unit in "${drain[@]}"; do
    : >"$pause_dir/$unit"
  done
  printf 'pausing units=%s\n' "${drain[*]}"
  # One deadline for every slot and the job containers: a job that runs
  # longer leaves the pool unpaused until the next check tries again.
  pause_deadline=$((SECONDS + pause_wait_seconds))
  for unit in "${drain[@]}"; do
    until [[ $(query show --property=StatusText --value "$unit" 2>/dev/null) == "paused tasks=0" ]]; do
      if ((SECONDS >= pause_deadline)); then
        unpause
        skip "pool_not_drained unit=$unit"
      fi
      sleep "$poll_seconds"
    done
    printf 'drained unit=%s\n' "$unit"
  done
  # A runner reports its job done before the job's container is gone.
  while job_containers "$podman_socket"; do
    if ((SECONDS >= pause_deadline)); then
      unpause
      skip "pool_not_drained socket=$podman_socket"
    fi
    sleep "$poll_seconds"
  done
fi
stop_started=$SECONDS
# Succeeds while the reset's pause still holds a drained pool runner: a
# runner restart removes every pause file when it ends.
pool_still_drained() {
  [[ -e $pause_dir/$1 ]] &&
    [[ $(query show --property=StatusText --value "$1" 2>/dev/null) == "paused tasks=0" ]]
}
for unit in "${to_stop[@]}"; do
  if job_containers "$docker_socket" "$podman_socket"; then skip "job_running socket=$job_socket"; fi
  if quiet_needed "$unit" && recent_job "$unit"; then skip "recent_job unit=$unit"; fi
  if ! quiet_needed "$unit" && ! pool_still_drained "$unit"; then
    unpause
    skip "pool_unpaused unit=$unit"
  fi
  timeout -k 5s "${runner_stop_timeout}s" "$systemctl_bin" stop "$unit" || fail "runner_stop unit=$unit"
done
# The drained runner is stopped; it must not start paused.
unpause
query is-active --quiet "$hold_unit" || skip hold_inactive
# A runner started meanwhile (the runner hold releasing a held runner) may
# have admitted a job, which the API stop would then wait for.
for unit in "${runner_units[@]}"; do
  unit_state "$unit" || skip "runner_unreadable unit=$unit"
  [[ -z $job && ($active == inactive || $active == failed) ]] || skip "runner_started unit=$unit"
done
timeout -k 5s 300s "$systemctl_bin" stop "${api_units[@]}" || fail api_stop

# 5. Rename under the start lock. Every runner and API start gate takes the
#    same lock first, so none can start between this proof and the rename.
exec 9>"$state_dir/start.lock"
flock -w 60 -x 9 || skip start_locked
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
  [[ -z $scratch_store || ($mount_point != "$scratch_store" && $mount_point != "$scratch_store"/*) ]] ||
    skip "store_mounted path=$mount_point"
done <"$mountinfo_file"
# Renames one store directory to its trash name.
rename_store() {
  local path=$1 parent=$2 trash=$3$now
  [[ -e $path || -L $path ]] || return 0
  [[ -d $path && ! -L $path && ! -e $trash ]] || fail "store_untrusted path=$path"
  # Same device, so mv is one rename(2) and never a copy.
  [[ $(stat -c '%d' -- "$path") == "$(stat -c '%d' -- "$parent")" ]] || fail "store_device path=$path"
  mv -T -- "$path" "$trash" || fail "rename path=$path"
}
# The scratch graphroot goes first: a crash between the two renames then
# leaves an empty graphroot beside an intact image store, never containers
# whose image layers are gone. A full scratch resets only the scratch: the
# images stay valid without the containers, and pulling them again would
# write the disk this scratch exists to spare.
[[ -z $scratch_store ]] || rename_store "$scratch_store" "$scratch_parent" "$scratch_trash_prefix"
if ((scratch_only == 0)); then
  rename_store "$store_path" "$store_parent" "$trash_prefix"
  printf '%s\n' "$now" >"$stamp"
  # Commit the rename and the stamp together, so a crash cannot keep the old
  # store while the age clock restarts.
  sync -- "$store_parent" "$stamp" || fail sync
fi
if [[ -e $legacy_fence || -L $legacy_fence ]]; then
  "$remove_bin" -rf -- "$legacy_fence" || fail legacy_fence
fi
exec 9>&-
# The scratch trash is RAM the restarted API and its next job need, and a
# full scratch would fail the API's own start: free it now, whatever the
# host's I/O pressure, since deleting from a tmpfs writes no disk.
if [[ -n $scratch_store && -d $scratch_trash_prefix$now && ! -L $scratch_trash_prefix$now ]]; then
  "$remove_bin" -rf --one-file-system -- "$scratch_trash_prefix$now" ||
    printf 'trash_skipped reason=not_removed path=%s\n' "$scratch_trash_prefix$now"
fi

# 6. Start again at once; the start gates still decide each start.
start_again "${api_units[@]}" "${to_stop[@]}" || fail start
rm -f -- "$restart_file"
printf 'reset due=%s stopped_seconds=%s\n' "$due" $((SECONDS - stop_started))

# 7. The old store is garbage now.
started=$SECONDS
if delete_trash; then
  printf 'trash_deleted seconds=%s\n' $((SECONDS - started))
fi
