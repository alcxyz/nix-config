#!/usr/bin/env bash
set -euo pipefail

state_dir=${STATE_DIR:-/run/forgejo-runner-aggregate-pressure}
pressure_file=${PRESSURE_FILE:-/proc/pressure/io}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
notify_bin=${SYSTEMD_NOTIFY_BIN:-systemd-notify}
logger_bin=${LOGGER_BIN:-logger}
sample_seconds=${SAMPLE_SECONDS:-5}
high_threshold=${HIGH_THRESHOLD_HUNDREDTHS:-2000}
low_threshold=${LOW_THRESHOLD_HUNDREDTHS:-500}
high_required=${HIGH_SAMPLES_REQUIRED:-5}
low_required=${LOW_SAMPLES_REQUIRED:-13}
admission_control=${ADMISSION_CONTROL_ENABLED:-0}
severe_threshold=${SEVERE_THRESHOLD_HUNDREDTHS:-6000}
severe_required=${SEVERE_SAMPLES_REQUIRED:-7}
max_iterations=${MAX_ITERATIONS:-0}
transition_timeout_seconds=${TRANSITION_TIMEOUT_SECONDS:-120}
unit=forgejobuilds.slice
runner_unit=forgejo-actions-runner.service
lifecycle_unit=forgejo-runner-aggregate-lifecycle.service
frozen_since=""
locked_metadata_deadline=0

# Diagnostic output must never change freeze ownership or recovery behavior.
report_transition() {
  local event=$1 details=${2:-} sampled_pressure=${pressure:-unknown}
  [[ $sampled_pressure =~ ^[0-9]+$ ]] || sampled_pressure=unknown
  printf 'event=%s unit=%s sampled_full_avg10_hundredths=%s %s\n' \
    "$event" "$unit" "$sampled_pressure" "$details" || true
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
mkdir -p "$state_dir"
chmod 0700 "$state_dir"
[[ ! -e $state_dir/pending ]] || fail "ambiguous freeze operation requires operator recovery"
[[ ! -e $state_dir/drain-pending ]] || fail "ambiguous admission drain requires operator recovery"
[[ ! -e $state_dir/resume-pending ]] || fail "ambiguous admission resume requires operator recovery"
[[ ! -e $state_dir/drain-disowned ]] || fail "disowned admission drain requires operator recovery"
[[ ! -e $state_dir/teardown-required ]] || fail "aggregate teardown requires operator recovery"
exec 9>"$state_dir/lifecycle.lock"

case "$admission_control" in
  0 | 1) ;;
  *) fail "invalid admission control setting" ;;
esac
if [[ $admission_control == 0 && -e $state_dir/drain-owned ]]; then
  fail "admission drain ownership remains while admission control is disabled"
fi

read_pressure() {
  if [[ -n ${PRESSURE_VALUES_FILE:-} ]]; then
    IFS= read -r pressure <&8 || return 1
    [[ $pressure =~ ^[0-9]+$ ]] || return 1
  else
    pressure=$(awk '
      $1 == "full" {
        for (i = 2; i <= NF; i++) {
          if ($i ~ /^avg10=[0-9]+([.][0-9]+)?$/) {
            split($i, part, "="); printf "%.0f\n", part[2] * 100; found = 1
          }
        }
      }
      END { if (!found) exit 1 }
    ' "$pressure_file") || return 1
  fi
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
  local started duration=unknown
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
  report_transition thawed "transition_seconds=$((SECONDS - started)) frozen_seconds=$duration"
  frozen_since=""
  unlock_lifecycle
}

request_admission_drain() {
  local active generation load_state unit_file_state result
  [[ $admission_control == 1 ]] || return 0
  [[ ! -e $state_dir/drain-owned ]] || return 0
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

  printf '%s\n' "$generation" > "$state_dir/drain-pending"
  rm -f "$state_dir/resume-blocked-reported"
  report_transition admission_drain_requested "runner_unit=$runner_unit active_state=$active"
  if ! metadata --no-block stop "$runner_unit"; then
    fail "runner admission drain failed; ownership requires recovery"
  fi
  mv "$state_dir/drain-pending" "$state_dir/drain-owned"
  locked_metadata_deadline=$((SECONDS + 45))
  active=$(runner_property ActiveState) || fail "cannot inspect draining runner state"
  report_transition admission_draining "runner_unit=$runner_unit active_state=$active"
  unlock_lifecycle
}

validate_drain_ownership() {
  local active current_generation owned_generation
  [[ $admission_control == 1 && -e $state_dir/drain-owned ]] || return 0

  IFS= read -r owned_generation < "$state_dir/drain-owned" ||
    fail "cannot read owned runner generation"
  [[ $owned_generation =~ ^[1-9][0-9]*$ ]] || fail "owned runner generation is invalid"
  active=$(runner_property ActiveState) || fail "cannot inspect owned runner state"
  current_generation=$(runner_property ExecMainStartTimestampMonotonic) ||
    fail "cannot inspect owned runner generation"
  [[ $current_generation =~ ^[0-9]+$ ]] || fail "owned runner has an invalid execution generation"

  # systemd clears the execution timestamp after a clean stop. The persisted
  # drain marker remains authoritative while the unit is no longer starting or
  # running. Any observed new generation is external to the owned stop.
  if [[ $current_generation == 0 && $active != active && $active != activating ]]; then
    return 0
  fi
  if [[ $current_generation != "$owned_generation" ]]; then
    mv "$state_dir/drain-owned" "$state_dir/drain-disowned"
    report_transition admission_drain_disowned "runner_unit=$runner_unit reason=runner_generation_changed"
    fail "runner generation changed during owned admission drain; operator recovery required"
  fi
}

resume_admissions() {
  local active load_state unit_file_state result
  [[ $admission_control == 1 && -e $state_dir/drain-owned ]] || return 0
  lock_lifecycle
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
    if [[ ! -e $state_dir/resume-blocked-reported ]]; then
      report_transition admission_resume_blocked \
        "runner_unit=$runner_unit active_state=$active load_state=$load_state unit_file_state=$unit_file_state result=$result"
      : > "$state_dir/resume-blocked-reported"
    fi
    unlock_lifecycle
    return 0
  fi

  mv "$state_dir/drain-owned" "$state_dir/resume-pending"
  rm -f "$state_dir/resume-blocked-reported"
  report_transition admission_resume_requested "runner_unit=$runner_unit active_state=$active"
  if ! metadata --no-block start "$runner_unit"; then
    fail "runner admission resume failed; ownership requires recovery"
  fi
  rm "$state_dir/resume-pending"
  report_transition admission_start_queued "runner_unit=$runner_unit"
  unlock_lifecycle
}

actual=$(freezer_state) || fail "cannot inspect build aggregate at startup"
if [[ -e $state_dir/owned ]]; then
  [[ $actual == frozen ]] || fail "prior freeze ownership no longer matches aggregate"
elif [[ $actual != running ]]; then
  fail "pre-existing aggregate freeze requires operator recovery"
fi
validate_drain_ownership
if [[ -n ${PRESSURE_VALUES_FILE:-} ]]; then exec 8<"$PRESSURE_VALUES_FILE"; fi
read_pressure || fail "I/O pressure is unreadable at startup"
"$notify_bin" --ready --status="monitoring dedicated CI aggregate" || true
high=0
severe=0
low=0
iteration=0
while ((max_iterations == 0 || iteration < max_iterations)); do
  iteration=$((iteration + 1))
  [[ ! -e $state_dir/teardown-required ]] || fail "aggregate teardown is in progress"
  validate_drain_ownership
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
  if ((pressure >= severe_threshold)); then
    severe=$((severe + 1))
  else
    severe=0
  fi
  if [[ $admission_control == 1 ]] && ((high >= high_required)); then
    request_admission_drain
    high=0
  fi
  if [[ -e $state_dir/owned ]]; then
    freeze_owned
    if ((low >= low_required)); then
      thaw_owned
    fi
  elif { [[ $admission_control == 1 ]] && ((severe >= severe_required)); } ||
    { [[ $admission_control == 0 ]] && ((high >= high_required)); }; then
    freeze_owned
    severe=0
    if [[ $admission_control == 0 ]]; then high=0; fi
  fi
  if ((low >= low_required)); then
    # Recovery always thaws the aggregate before asking the runner to poll
    # again. If jobs are still draining, resume_admissions keeps waiting for a
    # fully inactive unit while the low-pressure streak continues.
    resume_admissions
    low=$low_required
  fi
  if ((max_iterations != 0 && iteration >= max_iterations)); then break; fi
  sleep "$sample_seconds"
  if ! read_pressure; then
    freeze_owned
    fail "I/O pressure became unreadable; leaving owned aggregate frozen"
  fi
done
