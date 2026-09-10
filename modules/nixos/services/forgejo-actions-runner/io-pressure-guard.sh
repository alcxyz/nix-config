#!/usr/bin/env bash
set +e
set -u -o pipefail

pressure_file=${PRESSURE_FILE:-/proc/pressure/io}
state_dir=${STATE_DIR:-/run/forgejo-runner-pressure}
paused_dir=$state_dir/paused
pending_dir=$state_dir/pending
uncertain_dir=$state_dir/uncertain
label=${RUNNER_CONTAINER_LABEL:?RUNNER_CONTAINER_LABEL is required}
high_threshold=${HIGH_THRESHOLD_HUNDREDTHS:-2000}
low_threshold=${LOW_THRESHOLD_HUNDREDTHS:-500}
high_samples_required=${HIGH_SAMPLES_REQUIRED:-5}
low_samples_required=${LOW_SAMPLES_REQUIRED:-13}
sample_seconds=${SAMPLE_SECONDS:-5}
docker_timeout_seconds=${DOCKER_TIMEOUT_SECONDS:-3}
max_iterations=${MAX_ITERATIONS:-0}
docker_bin=${DOCKER_BIN:-docker}
logger_bin=${LOGGER_BIN:-logger}
notify_bin=${SYSTEMD_NOTIFY_BIN:-systemd-notify}

log() { "$logger_bin" -t forgejo-runner-io-pressure-guard -- "$1"; }
set_status() { "$notify_bin" --status="$1" 2>/dev/null || true; }
degraded() {
  log "degraded: $1"
  set_status "degraded: $1"
}
docker_command() { timeout --foreground "${docker_timeout_seconds}s" "$docker_bin" "$@"; }

enter_guarded() {
  if ! : >"$state_dir/guarded"; then
    degraded "guard state could not be persisted"
    exit 1
  fi
}

if ! mkdir -p "$paused_dir" "$pending_dir" "$uncertain_dir" ||
  ! chmod 0700 "$state_dir" "$paused_dir" "$pending_dir" "$uncertain_dir"; then
  degraded "ownership state directory could not be initialized"
  exit 1
fi
if [[ -e $state_dir/guarded && ! -f $state_dir/guarded ]]; then
  degraded "guard state is not a regular file"
  exit 1
fi

read_pressure() {
  local value
  if [[ -n ${PRESSURE_VALUES_FILE:-} ]]; then
    if ! IFS= read -r value <&8; then return 1; fi
    awk -v value="$value" 'BEGIN { if (value !~ /^[0-9]+([.][0-9]+)?$/) exit 1; printf "%.0f\n", value * 100 }'
    return
  fi
  [[ -r $pressure_file ]] || return 1
  awk '
    $1 == "full" {
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^avg10=[0-9]+([.][0-9]+)?$/) {
          split($i, part, "=")
          printf "%.0f\n", part[2] * 100
          found = 1
        }
      }
    }
    END { if (!found) exit 1 }
  ' "$pressure_file"
}

list_owned() {
  local status=${1:-running}
  docker_command ps --filter "label=$label" --filter "status=$status" --format '{{.ID}}'
}
inspect_paused() { docker_command inspect --format '{{.State.Paused}}' "$1" 2>/dev/null; }
container_exists() {
  local matches
  if ! matches=$(docker_command ps --all --no-trunc --quiet --filter "id=$1"); then return 2; fi
  [[ -n $matches ]]
}

reconcile_pending() {
  local marker container state exists_status
  for marker in "$pending_dir"/*; do
    [[ -e $marker ]] || return 0
    container=${marker##*/}
    if state=$(inspect_paused "$container"); then
      if [[ $state == true ]]; then
        if ! mv "$marker" "$uncertain_dir/$container"; then
          degraded "pending pause ownership could not be preserved"
          return 1
        fi
        degraded "a pause completed before ownership was recorded; operator recovery is required"
      else
        rm -f "$marker"
      fi
      continue
    fi
    container_exists "$container"
    exists_status=$?
    if ((exists_status == 1)); then
      rm -f "$marker"
    elif ((exists_status == 2)); then
      degraded "Docker API unavailable while reconciling pending pause intent"
      return 1
    else
      degraded "Docker API could not inspect a pending runner container"
      return 1
    fi
  done
}

pause_running_owned() {
  local containers container marker pending
  if ! containers=$(list_owned running); then
    degraded "Docker API unavailable while listing runner containers"
    return 1
  fi
  while IFS= read -r container; do
    [[ $container =~ ^[0-9a-f]{12,64}$ ]] || continue
    marker=$paused_dir/$container
    pending=$pending_dir/$container
    [[ -e $uncertain_dir/$container ]] && continue
    if [[ -e $marker ]]; then
      if ! docker_command pause "$container" >/dev/null; then
        degraded "Docker API failed while re-pausing an owned runner container"
      fi
      continue
    fi
    if ! : >"$pending"; then
      degraded "pause intent could not be recorded"
      continue
    fi
    if docker_command pause "$container" >/dev/null; then
      if [[ ${TEST_EXIT_AFTER_PAUSE:-0} == 1 ]]; then exit 99; fi
      if : >"$marker"; then
        rm -f "$pending"
      else
        degraded "pause ownership could not be recorded; leaving the container paused"
      fi
    else
      degraded "Docker API failed while pausing a runner container; retaining pending intent"
    fi
  done <<<"$containers"
}

abandon_ambiguous_resume() {
  local marker container
  [[ -e $state_dir/resume-intent ]] || return 0
  for marker in "$paused_dir"/*; do
    [[ -e $marker ]] || continue
    container=${marker##*/}
    if ! mv "$marker" "$uncertain_dir/$container"; then
      degraded "ambiguous resume ownership could not be preserved"
      return 2
    fi
  done
  if ! rm -f "$state_dir/resume-intent"; then
    degraded "ambiguous resume intent could not be cleared"
    return 2
  fi
  degraded "a prior batch resume has ambiguous ownership; operator recovery is required"
  return 3
}

resume_owned_batch() {
  local marker container state exists_status rollback_ok abandon_status
  local -a containers=()
  abandon_status=0
  abandon_ambiguous_resume || abandon_status=$?
  ((abandon_status == 0)) || return 2
  reconcile_pending || return 2
  if compgen -G "$uncertain_dir/*" >/dev/null; then
    degraded "paused runner containers with uncertain ownership require operator recovery"
    return 2
  fi
  for marker in "$paused_dir"/*; do
    [[ -e $marker ]] || continue
    container=${marker##*/}
    if state=$(inspect_paused "$container"); then
      if [[ $state == true ]]; then containers+=("$container"); else rm -f "$marker"; fi
      continue
    fi
    container_exists "$container"
    exists_status=$?
    if ((exists_status == 1)); then
      rm -f "$marker"
    elif ((exists_status == 2)); then
      degraded "Docker API unavailable while checking an owned paused container"
      return 2
    else
      degraded "Docker API could not inspect an owned paused container"
      return 2
    fi
  done
  (("${#containers[@]}" > 0)) || return 1
  if ! : >"$state_dir/resume-intent"; then
    degraded "batch resume intent could not be recorded"
    return 2
  fi
  if docker_command unpause "${containers[@]}" >/dev/null; then
    if [[ ${TEST_EXIT_AFTER_UNPAUSE:-0} == 1 ]]; then exit 98; fi
    for container in "${containers[@]}"; do rm -f "$paused_dir/$container"; done
    rm -f "$state_dir/resume-intent"
    log "resumed the pressure-guard-owned runner container batch"
    return 0
  fi
  degraded "Docker API failed while resuming the runner container batch; restoring pauses"
  rollback_ok=1
  for container in "${containers[@]}"; do
    if state=$(inspect_paused "$container"); then
      if [[ $state != true ]] && ! docker_command pause "$container" >/dev/null; then
        degraded "Docker API failed while restoring a runner container pause"
        rollback_ok=0
      fi
    else
      degraded "Docker API unavailable while verifying a failed batch resume"
      rollback_ok=0
    fi
  done
  if ((rollback_ok)); then
    rm -f "$state_dir/resume-intent"
  else
    abandon_ambiguous_resume || true
  fi
  return 2
}

has_recovery_state() {
  [[ -e $state_dir/resume-intent ]] ||
    compgen -G "$paused_dir/*" >/dev/null ||
    compgen -G "$pending_dir/*" >/dev/null ||
    compgen -G "$uncertain_dir/*" >/dev/null
}

if [[ -n ${PRESSURE_VALUES_FILE:-} ]]; then exec 8<"$PRESSURE_VALUES_FILE"; fi
if ! pressure=$(read_pressure); then
  degraded "I/O pressure is unreadable or malformed at startup"
  exit 1
fi
if ! list_owned running >/dev/null || ! list_owned paused >/dev/null; then
  degraded "Docker API unavailable at startup"
  exit 1
fi
abandon_status=0
abandon_ambiguous_resume || abandon_status=$?
if ((abandon_status == 2)); then
  exit 1
fi
if ! reconcile_pending; then
  exit 1
fi
if has_recovery_state; then
  enter_guarded
  "$notify_bin" --ready --status="degraded: runner pause ownership requires recovery" 2>/dev/null || true
else
  "$notify_bin" --ready --status="monitoring runner I/O pressure" 2>/dev/null || true
fi
high_samples=0
low_samples=0
iterations=0
have_pressure=1

while ((max_iterations == 0 || iterations < max_iterations)); do
  iterations=$((iterations + 1))
  if ((have_pressure)); then
    have_pressure=0
  elif ! pressure=$(read_pressure); then
    high_samples=0
    low_samples=0
    degraded "I/O pressure is unreadable or malformed"
    enter_guarded
    pause_running_owned || true
  elif ((pressure >= high_threshold)); then
    high_samples=$((high_samples + 1))
    low_samples=0
  elif ((pressure <= low_threshold)); then
    low_samples=$((low_samples + 1))
    high_samples=0
  else
    high_samples=0
    low_samples=0
  fi

  if [[ -e $state_dir/guarded ]]; then
    pause_running_owned || true
    if ((low_samples >= low_samples_required)); then
      resume_status=0
      resume_owned_batch || resume_status=$?
      if ((resume_status == 0 || resume_status == 1)); then
        if ! has_recovery_state; then
          rm -f "$state_dir/guarded"
          log "I/O pressure guard cleared; no owned or ambiguous pauses remain"
          set_status "monitoring runner I/O pressure"
        fi
      fi
      low_samples=0
    fi
  elif ((high_samples >= high_samples_required)); then
    enter_guarded
    log "sustained I/O pressure detected; pausing owned runner containers"
    pause_running_owned || true
    high_samples=0
  fi

  if ((max_iterations == 0 || iterations < max_iterations)); then sleep "$sample_seconds"; fi
done
