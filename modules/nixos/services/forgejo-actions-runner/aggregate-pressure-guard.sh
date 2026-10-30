#!/usr/bin/env bash
set -euo pipefail

state_dir=${STATE_DIR:-/run/forgejo-runner-aggregate-pressure}
pressure_file=${PRESSURE_FILE:-/proc/pressure/io}
slice_pressure_file=${SLICE_PRESSURE_FILE:-/sys/fs/cgroup/forgejobuilds.slice/io.pressure}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
notify_bin=${SYSTEMD_NOTIFY_BIN:-systemd-notify}
logger_bin=${LOGGER_BIN:-logger}
sample_seconds=${SAMPLE_SECONDS:-5}
high_threshold=${HIGH_THRESHOLD_HUNDREDTHS:-2000}
low_threshold=${LOW_THRESHOLD_HUNDREDTHS:-500}
high_required=${HIGH_SAMPLES_REQUIRED:-5}
low_required=${LOW_SAMPLES_REQUIRED:-13}
settled_required=${SETTLED_SAMPLES_REQUIRED:-61}
prolonged_required=${PROLONGED_DRAIN_SAMPLES:-360}
admission_control=${ADMISSION_CONTROL_ENABLED:-0}
# shellcheck disable=SC1090
source "${GAME_HELPER_FILE:-$(dirname "${BASH_SOURCE[0]}")/game-admission.sh}"
# shellcheck disable=SC1090
source "${DISK_HELPER_FILE:-$(dirname "${BASH_SOURCE[0]}")/disk-space-admission.sh}"
severe_threshold=${SEVERE_THRESHOLD_HUNDREDTHS:-6000}
severe_required=${SEVERE_SAMPLES_REQUIRED:-7}
max_iterations=${MAX_ITERATIONS:-0}
transition_timeout_seconds=${TRANSITION_TIMEOUT_SECONDS:-120}
resume_retry_max_samples=${RESUME_RETRY_MAX_SAMPLES:-60}
unit=forgejobuilds.slice
primary_runner=forgejo-actions-runner.service
runner_unit=$primary_runner
runner_state=$state_dir
runner_units_text=${RUNNER_UNITS:-$primary_runner}
lifecycle_unit=forgejo-runner-aggregate-lifecycle.service
frozen_since=""
locked_metadata_deadline=0

# Diagnostic output must never change freeze ownership or recovery behavior.
report_transition() {
  local event=$1 details=${2:-} sampled_pressure=${pressure:-unknown}
  [[ $sampled_pressure =~ ^[0-9]+$ ]] || sampled_pressure=unknown
  printf 'event=%s unit=%s sampled_full_avg10_hundredths=%s sampled_disk_free_bytes=%s sampled_disk_free_percent=%s %s\n' \
    "$event" "$unit" "$sampled_pressure" "${disk_free_bytes:-unknown}" "${disk_free_percent:-unknown}" "$details" || true
}

fail() {
  "$logger_bin" -t forgejo-runner-aggregate-pressure -- "$1"
  "$notify_bin" --status="degraded: $1" || true
  exit 1
}
metadata() {
  local output deadline remaining attempt_timeout
  if [[ $1 != show ]]; then
    timeout --foreground 5s "$systemctl_bin" "$@"
    return
  fi
  # daemon-reload briefly blocks read-only D-Bus queries during a NixOS
  # switch. Keep existing ownership intact across that bounded interval;
  # never retry a start or stop request whose result could be ambiguous.
  deadline=$((SECONDS + 45))
  if ((locked_metadata_deadline > 0 && locked_metadata_deadline < deadline)); then
    deadline=$locked_metadata_deadline
  fi
  while :; do
    remaining=$((deadline - SECONDS))
    ((remaining > 0)) || return 1
    attempt_timeout=10
    ((remaining < attempt_timeout)) && attempt_timeout=$remaining
    if output=$(timeout --foreground "${attempt_timeout}s" "$systemctl_bin" "$@"); then
      printf '%s\n' "$output"
      return 0
    fi
    ((SECONDS < deadline)) || return 1
    sleep 1
  done
}
lock_lifecycle() {
  flock -x 9
  locked_metadata_deadline=$((SECONDS + 45))
}
unlock_lifecycle() {
  locked_metadata_deadline=0
  flock -u 9
}
transition() {
  local action=$1
  local actual deadline metadata_timeout remaining
  shift
  deadline=$((SECONDS + transition_timeout_seconds))

  while ((remaining = deadline - SECONDS, remaining > 0)); do
    if SYSTEMD_BUS_TIMEOUT="${remaining}s" timeout --foreground "${remaining}s" "$systemctl_bin" "$action" "$@"; then
      return 0
    fi
    [[ $action == freeze ]] || return 1

    remaining=$((deadline - SECONDS))
    ((remaining > 0)) || return 1
    metadata_timeout=5
    ((remaining < metadata_timeout)) && metadata_timeout=$remaining
    actual=$(timeout --foreground "${metadata_timeout}s" "$systemctl_bin" \
      show --property=FreezerState --value "$unit") || return 1
    [[ $actual == running ]] || return 1

    remaining=$((deadline - SECONDS))
    ((remaining > 1)) || return 1
    sleep 1
  done
  return 1
}
freezer_state() { metadata show --property=FreezerState --value "$unit"; }
runner_property() {
  metadata show --property="$1" --value "$runner_unit"
}
runner_state_dir() {
  if [[ $1 == "$primary_runner" ]]; then
    printf '%s\n' "$state_dir"
  else
    printf '%s/runners/%s\n' "$state_dir" "$1"
  fi
}
validate_runner_units() {
  local candidate other path known
  IFS=$' \t\n' read -r -d '' -a runner_units <<< "$runner_units_text" || true
  ((${#runner_units[@]} > 0)) || fail "runner unit list is empty"
  [[ ${runner_units[0]} == "$primary_runner" ]] || fail "primary runner must remain first"
  for candidate in "${runner_units[@]}"; do
    [[ $candidate =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || fail "invalid runner unit name"
    for other in "${seen_units[@]}"; do
      [[ $candidate != "$other" ]] || fail "duplicate runner unit"
    done
    seen_units+=("$candidate")
  done
  # A changed list or leftover per-runner state needs explicit recovery. Do
  # not silently assign persisted drain ownership to a different service.
  if [[ -e $state_dir/runner-units ]]; then
    [[ $(cat "$state_dir/runner-units") == "$(printf '%s\n' "${runner_units[@]}")" ]] ||
      fail "runner unit configuration changed with persistent state"
  else
    printf '%s\n' "${runner_units[@]}" > "$state_dir/runner-units"
  fi
  for path in "$state_dir"/runners/*; do
    [[ -e $path || -L $path ]] || continue
    [[ -d $path && ! -L $path ]] || fail "invalid runner state directory"
    known=0
    for candidate in "${runner_units[@]:1}"; do
      [[ $path != "$state_dir/runners/$candidate" ]] || known=1
    done
    ((known == 1)) || fail "unknown runner state directory"
  done
  for candidate in "${runner_units[@]:1}"; do
    mkdir -p "$state_dir/runners/$candidate"
    chmod 0700 "$state_dir/runners/$candidate"
  done
}
mkdir -p "$state_dir"
chmod 0700 "$state_dir"
[[ ! -e $state_dir/pending ]] || fail "ambiguous freeze operation requires operator recovery"
[[ ! -e $state_dir/teardown-required ]] || fail "aggregate teardown requires operator recovery"
exec 9>"$state_dir/lifecycle.lock"
flock -x 9
seen_units=()
validate_runner_units

case "$admission_control" in
  0 | 1) ;;
  *) fail "invalid admission control setting" ;;
esac
[[ $resume_retry_max_samples =~ ^[1-9][0-9]*$ ]] || fail "invalid resume retry bound"
for runner_unit in "${runner_units[@]}"; do
  runner_state=$(runner_state_dir "$runner_unit")
  [[ ! -e $runner_state/drain-pending ]] || fail "ambiguous admission drain requires operator recovery"
  [[ ! -e $runner_state/resume-pending ]] || fail "ambiguous admission resume requires operator recovery"
  [[ ! -e $runner_state/drain-disowned ]] || fail "disowned admission drain requires operator recovery"
  if [[ $admission_control == 0 && -e $runner_state/drain-owned ]]; then
    fail "admission drain ownership remains while admission control is disabled"
  fi
  if [[ $admission_control == 0 && -e $runner_state/game-start-skipped ]]; then
    fail "game start ownership remains while admission control is disabled"
  fi
  if [[ $admission_control == 0 && -e $runner_state/disk-start-skipped ]]; then
    fail "disk start ownership remains while admission control is disabled"
  fi
  if [[ $admission_control == 0 && -e $runner_state/resume-queued ]]; then
    fail "queued resume ownership remains while admission control is disabled"
  fi
  if [[ -e $runner_state/resume-queued ]]; then
    IFS= read -r queued_stamp < "$runner_state/resume-queued" || queued_stamp=''
    [[ $queued_stamp =~ ^[0-9]+$ ]] || fail "queued resume ownership is invalid"
  fi
done
flock -u 9

full_avg10_hundredths() {
  awk '
    $1 == "full" {
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^avg10=[0-9]+([.][0-9]+)?$/) {
          split($i, part, "="); printf "%.0f\n", part[2] * 100; found = 1
        }
      }
    }
    END { if (!found) exit 1 }
  ' "$1"
}
read_pressure() {
  if [[ -n ${PRESSURE_VALUES_FILE:-} ]]; then
    IFS= read -r pressure <&8 || return 1
    [[ $pressure =~ ^[0-9]+$ ]] || return 1
  else
    pressure=$(full_avg10_hundredths "$pressure_file") || return 1
  fi
}
# The aggregate's own stall time is a weak hint that CI is not the cause:
# buffered ZFS writeback is not charged to it. It only gates the settled resume
# path, so an unreadable sample withholds that path instead of failing the
# guard.
read_slice_pressure() {
  slice_pressure=unknown
  if [[ -n ${SLICE_PRESSURE_VALUES_FILE:-} ]]; then
    IFS= read -r slice_pressure <&6 || slice_pressure=unknown
  else
    slice_pressure=$(full_avg10_hundredths "$slice_pressure_file" 2>/dev/null) || slice_pressure=unknown
  fi
  [[ $slice_pressure =~ ^[0-9]+$ ]] || slice_pressure=unknown
}

freeze_owned() {
  local actual started
  lock_lifecycle
  [[ ! -e $state_dir/teardown-required ]] || fail "aggregate teardown is in progress"
  # During boot, the daemon starts before the external lifecycle service.
  # Consumers require that service, so defer freezing until teardown is armed.
  if [[ $(metadata is-active "$lifecycle_unit" 2>/dev/null || true) != active ]]; then
    unlock_lifecycle
    return 0
  fi
  actual=$(freezer_state) || fail "cannot inspect build aggregate"
  if [[ -e $state_dir/owned ]]; then
    [[ $actual == frozen ]] || fail "owned aggregate was thawed externally"
    unlock_lifecycle
    return
  fi
  [[ $actual == running ]] || fail "aggregate freeze is not owned by this guard"
  : > "$state_dir/pending"
  started=$SECONDS
  report_transition freeze_requested
  transition freeze "$unit" || fail "aggregate freeze failed; ownership requires recovery"
  locked_metadata_deadline=$((SECONDS + 45))
  [[ $(freezer_state) == frozen ]] || fail "aggregate did not freeze; ownership requires recovery"
  : > "$state_dir/owned"
  rm "$state_dir/pending"
  frozen_since=$SECONDS
  report_transition frozen "transition_seconds=$((SECONDS - started))"
  unlock_lifecycle
}

thaw_owned() {
  local path=$1 started duration=unknown
  lock_lifecycle
  [[ ! -e $state_dir/teardown-required ]] || fail "aggregate teardown is in progress"
  [[ -e $state_dir/owned ]] || fail "aggregate thaw lacks ownership"
  [[ $(freezer_state) == frozen ]] || fail "owned aggregate state changed externally"
  : > "$state_dir/pending"
  started=$SECONDS
  report_transition thaw_requested
  transition thaw "$unit" || fail "aggregate thaw failed; ownership requires recovery"
  locked_metadata_deadline=$((SECONDS + 45))
  [[ $(freezer_state) == running ]] || fail "aggregate did not thaw; ownership requires recovery"
  rm "$state_dir/owned" "$state_dir/pending"
  if [[ -n $frozen_since ]]; then duration=$((SECONDS - frozen_since)); fi
  report_transition thawed "thaw_path=$path transition_seconds=$((SECONDS - started)) frozen_seconds=$duration"
  frozen_since=""
  unlock_lifecycle
}

request_admission_drain() {
  local reason=${1:-pressure}
  local active generation load_state unit_file_state result
  [[ $admission_control == 1 ]] || return 0
  [[ ! -e $runner_state/drain-owned ]] || return 0
  lock_lifecycle
  [[ ! -e $state_dir/teardown-required ]] || fail "aggregate teardown is in progress"

  load_state=$(runner_property LoadState) || fail "cannot inspect runner load state"
  unit_file_state=$(runner_property UnitFileState) || fail "cannot inspect runner enablement"
  active=$(runner_property ActiveState) || fail "cannot inspect runner state"
  result=$(runner_property Result) || fail "cannot inspect runner result"
  generation=$(runner_property ExecMainStartTimestampMonotonic) || fail "cannot inspect runner generation"

  # Only a healthy, enabled runner that is currently polling can be claimed.
  # An inactive, failed, disabled, or masked service may have been stopped by
  # an operator and must never be restarted by this guard.
  if [[ $load_state != loaded || ($unit_file_state != enabled && $unit_file_state != enabled-runtime) || $active != active || $result != success ]]; then
    unlock_lifecycle
    return 0
  fi
  [[ $generation =~ ^[1-9][0-9]*$ ]] || fail "active runner has no valid execution generation"

  printf '%s\n' "$generation" > "$runner_state/drain-pending"
  rm -f "$runner_state/resume-blocked-reported"
  # Claiming requires an active runner, so a queued resume has taken effect.
  rm -f "$runner_state/resume-queued"
  forget_resume_retry
  report_transition admission_drain_requested "runner_unit=$runner_unit active_state=$active reason=$reason"
  if ! metadata --no-block stop "$runner_unit"; then
    fail "runner admission drain failed; ownership requires recovery"
  fi
  mv "$runner_state/drain-pending" "$runner_state/drain-owned"
  drain_reason=$reason
  locked_metadata_deadline=$((SECONDS + 45))
  active=$(runner_property ActiveState) || fail "cannot inspect draining runner state"
  report_transition admission_draining "runner_unit=$runner_unit active_state=$active"
  unlock_lifecycle
}

validate_drain_ownership() {
  local active current_generation owned_generation
  [[ $admission_control == 1 && -e $runner_state/drain-owned ]] || return 0

  IFS= read -r owned_generation < "$runner_state/drain-owned" ||
    fail "cannot read owned runner generation"
  [[ $owned_generation =~ ^[1-9][0-9]*$ ]] || fail "owned runner generation is invalid"
  active=$(runner_property ActiveState) || fail "cannot inspect owned runner state"
  current_generation=$(runner_property ExecMainStartTimestampMonotonic) ||
    fail "cannot inspect owned runner generation"
  [[ $current_generation =~ ^[0-9]+$ ]] || fail "owned runner has an invalid execution generation"

  # systemd clears the execution timestamp after a clean stop. A switch can
  # also leave the unit activating while ExecCondition waits for our lock;
  # no new runner main process has executed while the timestamp remains zero.
  # A positive different generation still disowns the drain in any state.
  if [[ $current_generation == 0 && $active != active ]]; then
    return 0
  fi
  if [[ $current_generation != "$owned_generation" ]]; then
    mv "$runner_state/drain-owned" "$runner_state/drain-disowned"
    report_transition admission_drain_disowned "runner_unit=$runner_unit reason=runner_generation_changed"
    fail "runner generation changed during owned admission drain; operator recovery required"
  fi
}

resume_admissions() {
  local path=${1:-low}
  local active load_state unit_file_state result marker stamp
  [[ $admission_control == 1 ]] || return 0
  # A queued resume keeps its own ownership until confirm_resume settles it.
  [[ ! -e $runner_state/resume-queued ]] || return 0
  if [[ -e $runner_state/drain-owned ]]; then
    marker=drain-owned
  elif [[ -e $runner_state/disk-start-skipped ]]; then
    marker=disk-start-skipped
  elif [[ -e $runner_state/game-start-skipped ]]; then
    marker=game-start-skipped
  else
    return 0
  fi
  lock_lifecycle
  # Cleanup can outlive its client and lifecycle flock. Withhold admission
  # without failing the guard or changing independent drain/freeze ownership.
  if [[ -e $state_dir/cleanup-in-flight || -L $state_dir/cleanup-in-flight ]]; then
    unlock_lifecycle
    return 0
  fi
  [[ ! -e $state_dir/teardown-required ]] || fail "aggregate teardown is in progress"

  load_state=$(runner_property LoadState) || fail "cannot inspect runner load state"
  unit_file_state=$(runner_property UnitFileState) || fail "cannot inspect runner enablement"
  active=$(runner_property ActiveState) || fail "cannot inspect runner state"
  result=$(runner_property Result) || fail "cannot inspect runner result"

  # A graceful stop can remain deactivating for the rest of the admitted job's
  # timeout. Keep waiting without sending another stop or start request.
  if [[ $active != inactive ]]; then unlock_lifecycle; return 0; fi
  # ExecCondition may have skipped a configuration-switch start while this
  # owned drain was in force. That benign result still permits guard recovery.
  if [[ $load_state != loaded || ($unit_file_state != enabled && $unit_file_state != enabled-runtime) ||
        ($result != success && $result != exec-condition) ]]; then
    if [[ ! -e $runner_state/resume-blocked-reported ]]; then
      report_transition admission_resume_blocked \
        "runner_unit=$runner_unit active_state=$active load_state=$load_state unit_file_state=$unit_file_state result=$result"
      : > "$runner_state/resume-blocked-reported"
    fi
    unlock_lifecycle
    return 0
  fi

  stamp=$(condition_stamp) || exit 1
  mv "$runner_state/$marker" "$runner_state/resume-pending"
  rm -f "$runner_state/resume-blocked-reported"
  report_transition admission_resume_requested \
    "runner_unit=$runner_unit active_state=$active reason=$marker resume_path=$path sampled_slice_full_avg10_hundredths=$slice_pressure"
  forget_resume_retry
  queue_resume_start "$stamp"
  report_transition admission_start_queued "runner_unit=$runner_unit"
  unlock_lifecycle
}

# Every start systemd processes evaluates the unit's conditions again and
# moves ConditionTimestampMonotonic, so the stamp read before queuing tells a
# start that is still queued from one that ran or was skipped. Read it before
# any marker changes: a failed read must leave ownership as it was.
condition_stamp() {
  local stamp
  stamp=$(runner_property ConditionTimestampMonotonic) || fail "cannot inspect runner condition timestamp"
  [[ $stamp =~ ^[0-9]+$ ]] || fail "runner condition timestamp is invalid"
  printf '%s\n' "$stamp"
}

# Called under the lifecycle lock with resume-pending in place. ExecCondition
# waits for this lock, so the gate cannot observe the intermediate state.
queue_resume_start() {
  printf '%s\n' "$1" > "$runner_state/resume-pending"
  if ! metadata --no-block start "$runner_unit"; then
    fail "runner admission resume failed; ownership requires recovery"
  fi
  mv "$runner_state/resume-pending" "$runner_state/resume-queued"
}

# Retry spacing is kept in memory: a restarted guard retries at once.
declare -A resume_retry_next=() resume_retry_delay=() resume_retry_count=()
forget_resume_retry() {
  unset "resume_retry_next[$runner_unit]" "resume_retry_delay[$runner_unit]" "resume_retry_count[$runner_unit]"
}

# A queued start can still be skipped: a unit condition (for example a runtime
# maintenance hold) or the start gate leaves the runner inactive with
# ConditionResult=no. The guard keeps ownership in resume-queued until the
# runner is active, then forgets it. A skip that left a gate hold marker
# (disk, game, standby) hands ownership to that marker's owner. Any other skip
# is reported once and the start is queued again with doubling spacing, capped
# at RESUME_RETRY_MAX_SAMPLES, only while resume would be allowed: every retry
# is a new start that systemd's conditions and the start gate evaluate again,
# and none follows an ambiguous request. A start that ran and stopped or
# failed, or a job that was cancelled or refused before its conditions ran,
# ends ownership;
# the guard never restarts a runner it did not see skipped. Disable or mask a
# runner to keep it off while a resume is outstanding.
confirm_resume() {
  local ready=$1
  local queued_stamp job stamp active condition result load_state unit_file_state marker delay count next
  [[ $admission_control == 1 && -e $runner_state/resume-queued ]] || return 0
  lock_lifecycle
  [[ ! -e $state_dir/teardown-required ]] || fail "aggregate teardown is in progress"
  IFS= read -r queued_stamp < "$runner_state/resume-queued" || fail "cannot read queued resume ownership"
  [[ $queued_stamp =~ ^[0-9]+$ ]] || fail "queued resume ownership is invalid"
  # Read the job before the stamp: a job that has gone has already moved it.
  job=$(runner_property Job) || fail "cannot inspect runner job"
  stamp=$(condition_stamp) || exit 1
  active=$(runner_property ActiveState) || fail "cannot inspect runner state"
  condition=$(runner_property ConditionResult) || fail "cannot inspect runner condition result"
  result=$(runner_property Result) || fail "cannot inspect runner result"

  case "$active" in
    active | reloading)
      rm "$runner_state/resume-queued"
      rm -f "$runner_state/resume-blocked-reported"
      report_transition admission_resume_confirmed \
        "runner_unit=$runner_unit active_state=$active retries=${resume_retry_count[$runner_unit]:-0}"
      forget_resume_retry
      unlock_lifecycle
      return 0
      ;;
    inactive | failed) ;;
    *) unlock_lifecycle; return 0 ;;
  esac
  if [[ $stamp == "$queued_stamp" ]]; then
    if [[ -z $job || $job == 0 ]]; then
      rm "$runner_state/resume-queued"
      report_transition admission_resume_not_run \
        "runner_unit=$runner_unit active_state=$active result=$result"
      forget_resume_retry
    fi
    unlock_lifecycle
    return 0
  fi
  if [[ $active != inactive || ($condition != no && $result != exec-condition) ||
        ($result != success && $result != exec-condition) ]]; then
    rm "$runner_state/resume-queued"
    report_transition admission_resume_ended \
      "runner_unit=$runner_unit active_state=$active condition_result=$condition result=$result"
    forget_resume_retry
    unlock_lifecycle
    return 0
  fi
  for marker in disk-start-skipped game-start-skipped standby-held; do
    if [[ -e $runner_state/$marker ]]; then
      rm "$runner_state/resume-queued"
      report_transition admission_resume_handed_over "runner_unit=$runner_unit reason=$marker"
      forget_resume_retry
      unlock_lifecycle
      return 0
    fi
  done
  if [[ -z ${resume_retry_count[$runner_unit]:-} ]]; then
    resume_retry_count[$runner_unit]=0
    resume_retry_next[$runner_unit]=0
    resume_retry_delay[$runner_unit]=1
    report_transition admission_resume_skipped \
      "runner_unit=$runner_unit condition_result=$condition result=$result"
  fi
  count=${resume_retry_count[$runner_unit]}
  next=${resume_retry_next[$runner_unit]}
  delay=${resume_retry_delay[$runner_unit]}
  if ((ready != 1 || iteration < next)) ||
    [[ -e $state_dir/cleanup-in-flight || -L $state_dir/cleanup-in-flight || -e $state_dir/owned ]]; then
    unlock_lifecycle
    return 0
  fi
  load_state=$(runner_property LoadState) || fail "cannot inspect runner load state"
  unit_file_state=$(runner_property UnitFileState) || fail "cannot inspect runner enablement"
  if [[ $load_state != loaded || ($unit_file_state != enabled && $unit_file_state != enabled-runtime) ]]; then
    if [[ ! -e $runner_state/resume-blocked-reported ]]; then
      report_transition admission_resume_blocked \
        "runner_unit=$runner_unit active_state=$active load_state=$load_state unit_file_state=$unit_file_state result=$result"
      : > "$runner_state/resume-blocked-reported"
    fi
    unlock_lifecycle
    return 0
  fi
  rm -f "$runner_state/resume-blocked-reported"
  resume_retry_count[$runner_unit]=$((count + 1))
  resume_retry_next[$runner_unit]=$((iteration + delay))
  delay=$((delay * 2))
  ((delay <= resume_retry_max_samples)) || delay=$resume_retry_max_samples
  resume_retry_delay[$runner_unit]=$delay
  stamp=$(condition_stamp) || exit 1
  mv "$runner_state/resume-queued" "$runner_state/resume-pending"
  queue_resume_start "$stamp"
  unlock_lifecycle
}

# Succeeds when no runner with an owned drain is still finishing admitted jobs.
drained_runners_idle() {
  local unit active
  for unit in "${runner_units[@]}"; do
    [[ -e $(runner_state_dir "$unit")/drain-owned ]] || continue
    active=$(metadata show --property=ActiveState --value "$unit") || return 1
    [[ $active == inactive ]] || return 1
  done
}

# Succeeds when no runner can admit a job: each one is drained by the guard or
# is not running. The jobs a draining runner already admitted still count.
admission_withheld() {
  local unit active
  for unit in "${runner_units[@]}"; do
    [[ ! -e $(runner_state_dir "$unit")/drain-owned ]] || continue
    active=$(metadata show --property=ActiveState --value "$unit") || return 1
    [[ $active == inactive || $active == failed || $active == deactivating ]] || return 1
  done
}

actual=$(freezer_state) || fail "cannot inspect build aggregate at startup"
if [[ -e $state_dir/owned ]]; then
  [[ $actual == frozen ]] || fail "prior freeze ownership no longer matches aggregate"
elif [[ $actual != running ]]; then
  fail "pre-existing aggregate freeze requires operator recovery"
fi
for runner_unit in "${runner_units[@]}"; do
  runner_state=$(runner_state_dir "$runner_unit")
  validate_drain_ownership
done
if [[ -n ${PRESSURE_VALUES_FILE:-} ]]; then exec 8<"$PRESSURE_VALUES_FILE"; fi
if [[ -n ${SLICE_PRESSURE_VALUES_FILE:-} ]]; then exec 6<"$SLICE_PRESSURE_VALUES_FILE"; fi
if [[ ${DISK_SPACE_ENABLED:-0} == 1 && -n ${DISK_SPACE_VALUES_FILE:-} ]]; then
  exec 7<"$DISK_SPACE_VALUES_FILE"
  # The sourced disk helper consumes this stream flag.
  # shellcheck disable=SC2034
  DISK_SPACE_STREAM=1
fi
read_pressure || fail "I/O pressure is unreadable at startup"
read_slice_pressure
"$notify_bin" --ready --status="monitoring dedicated CI aggregate" || true
high=0
severe=0
low=0
recovered=0
settled=0
frozen_settled=0
drained=0
prolonged_reported=0
# A drain restored from persistent state has no recorded cause.
drain_reason=unknown
iteration=0
while ((max_iterations == 0 || iteration < max_iterations)); do
  iteration=$((iteration + 1))
  [[ ! -e $state_dir/teardown-required ]] || fail "aggregate teardown is in progress"
  for runner_unit in "${runner_units[@]}"; do
    runner_state=$(runner_state_dir "$runner_unit")
    validate_drain_ownership
  done
  if game_admission_status; then game_status=0; else game_status=$?; fi
  if ((game_status != 1)); then
    for runner_unit in "${runner_units[@]}"; do
      runner_state=$(runner_state_dir "$runner_unit")
      # shellcheck disable=SC2154
      request_admission_drain "$game_reason"
    done
  fi
  if disk_space_status; then disk_status=0; else disk_status=$?; fi
  if ((disk_status == 4)); then
    freeze_owned
    fail "runner filesystem free space is unreadable; leaving owned aggregate frozen"
  fi
  if ((disk_status == 1 || disk_status == 2)); then
    for runner_unit in "${runner_units[@]}"; do
      runner_state=$(runner_state_dir "$runner_unit")
      request_admission_drain disk_space
    done
  fi
  # Thawing depends on pressure alone: a freeze must not outlive its cause
  # while the disk sits between the drain and recovery floors, because the
  # frozen daemon cannot run the prune that would restore headroom. Resuming
  # admission still requires a consecutive recovered-disk streak.
  if ((pressure >= high_threshold)); then
    high=$((high + 1))
    low=0
  elif ((pressure <= low_threshold)); then
    low=$((low + 1))
    high=0
  else
    low=0
    high=0
  fi
  if ((low > 0 && disk_status == 0)); then
    recovered=$((recovered + 1))
  else
    recovered=0
  fi
  # A drain must not outlast its cause. Unrelated load that stays between the
  # resume and drain thresholds would otherwise withhold admission
  # indefinitely, so the drain also recovers after a longer settled interval
  # below the drain threshold. The interval starts only once every drained
  # runner has finished its admitted jobs, so load that CI writeback leaves
  # behind is not mistaken for unrelated load. It never counts during an owned
  # freeze, since frozen workers report no stall time; the freeze has its own
  # settled thaw below, and this interval starts after it.
  if ((pressure < high_threshold && disk_status == 0)) &&
    [[ $slice_pressure != unknown && ! -e $state_dir/owned ]] &&
    ((slice_pressure <= low_threshold)) && drained_runners_idle; then
    settled=$((settled + 1))
  else
    settled=0
  fi
  # A freeze must not outlast its cause either (#908). Unrelated load can hold
  # host pressure above the resume threshold for hours while the frozen jobs
  # can neither finish nor be cancelled, and a draining runner then dies at its
  # stop timeout. With admission withheld, an owned freeze therefore also thaws
  # after the settled interval below the drain threshold: the admitted jobs
  # then run under the same pressure that never freezes running jobs, and
  # severe pressure freezes them again.
  if [[ $admission_control == 1 && -e $state_dir/owned ]] &&
    ((pressure < high_threshold && disk_status != 2)) && admission_withheld; then
    frozen_settled=$((frozen_settled + 1))
  else
    frozen_settled=0
  fi
  if ((pressure >= severe_threshold)); then
    severe=$((severe + 1))
  else
    severe=0
  fi
  if [[ $admission_control == 1 ]] && ((high >= high_required)); then
    for runner_unit in "${runner_units[@]}"; do
      runner_state=$(runner_state_dir "$runner_unit")
      request_admission_drain
    done
    high=0
  fi
  if [[ -e $state_dir/owned ]]; then
    freeze_owned
    # A critical disk keeps active workers frozen until space is recovered.
    if ((low >= low_required && disk_status != 2)); then
      thaw_owned low
    elif ((frozen_settled >= settled_required)); then
      thaw_owned settled
    fi
  elif ((disk_status == 2)) ||
    { [[ $admission_control == 1 ]] && ((severe >= severe_required)); } ||
    { [[ $admission_control == 0 ]] && ((high >= high_required)); }; then
    freeze_owned
    severe=0
    if [[ $admission_control == 0 ]]; then high=0; fi
  fi
  if ((recovered >= low_required || settled >= settled_required)) && ((game_status == 1)); then
    resume_ready=1
  else
    resume_ready=0
  fi
  # Settle resumes queued on earlier samples before queuing new ones, so a
  # skip is seen only after systemd has had a sample to process the start.
  for runner_unit in "${runner_units[@]}"; do
    runner_state=$(runner_state_dir "$runner_unit")
    confirm_resume "$resume_ready"
  done
  if ((resume_ready == 1)); then
    # Recovery always thaws the aggregate before asking the runner to poll
    # again. If jobs are still draining, resume_admissions keeps waiting for a
    # fully inactive unit while the low-pressure streak continues.
    if ((recovered >= low_required)); then resume_path=low; else resume_path=settled; fi
    for runner_unit in "${runner_units[@]}"; do
      runner_state=$(runner_state_dir "$runner_unit")
      resume_admissions "$resume_path"
    done
    ((recovered < low_required)) || recovered=$low_required
    ((settled < settled_required)) || settled=$settled_required
  fi
  # Report, once per episode, a drain that has withheld admission for longer
  # than expected so it can be noticed before it blocks dependent work. A
  # detected game is an intended hold and restarts the count; detector faults
  # do not, since they hold admission without a game.
  owned_drains=0
  for runner_unit in "${runner_units[@]}"; do
    [[ ! -e $(runner_state_dir "$runner_unit")/drain-owned ]] || owned_drains=$((owned_drains + 1))
  done
  if ((owned_drains == 0)); then
    drained=0
    prolonged_reported=0
  elif [[ $game_reason == game_present || $game_reason == game_cooldown ]]; then
    drained=0
  elif ((drained++ == prolonged_required && prolonged_reported == 0)); then
    prolonged_reported=1
    report_transition admission_drain_prolonged \
      "drained_samples=$prolonged_required owned_drains=$owned_drains reason=$drain_reason sampled_slice_full_avg10_hundredths=$slice_pressure"
  fi
  if ((max_iterations != 0 && iteration >= max_iterations)); then break; fi
  sleep "$sample_seconds"
  if ! read_pressure; then
    freeze_owned
    fail "I/O pressure became unreadable; leaving owned aggregate frozen"
  fi
  read_slice_pressure
done
