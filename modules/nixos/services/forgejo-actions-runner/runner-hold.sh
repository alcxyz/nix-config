#!/usr/bin/env bash
set -euo pipefail

# Holds the CI runners while a reason applies and starts them again when it
# ends (ADR-0106). Reasons: a game on this host (the game signal), and free
# space below the disk floor. Every sample looks at the current state, so the
# controller keeps no transition state and may restart at any time.
#
# A runner the controller stops gets a `held` marker before the stop. The
# start gate leaves the same marker when it refuses a start for a reason. Once
# no reason applies, every marked runner that is inactive or failed is reset
# and started, retried with growing spacing, and its marker goes once the
# runner runs. A runner stopped by anyone else carries no marker and is never
# started; disabling or masking a marked runner drops its marker. The disk
# hold's state survives a controller restart as the `disk-held` file, which
# the start gate also reads.
#
# With alerting enabled, a runner that has been inactive or failed for longer
# than a bound while no reason, marker or running Podman store reset explains
# it fails the host's healthcheck ping.

state_dir=${STATE_DIR:-/run/forgejo-runner-hold}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
curl_bin=${CURL_BIN:-curl}
notify_bin=${SYSTEMD_NOTIFY_BIN:-systemd-notify}
uptime_file=${UPTIME_FILE:-/proc/uptime}
sample_seconds=${SAMPLE_SECONDS:-5}
max_iterations=${MAX_ITERATIONS:-0}
runner_units_text=${RUNNER_UNITS:-}
game_enabled=${GAME_ENABLED:-0}
game_file=${GAME_FILE:-/run/game-signal/active}
game_unit=${GAME_UNIT:-game-signal.service}
start_retry_max_seconds=${START_RETRY_MAX_SECONDS:-300}
alert_enabled=${ALERT_ENABLED:-0}
alert_interval_seconds=${ALERT_INTERVAL_SECONDS:-300}
max_inactive_seconds=${MAX_INACTIVE_SECONDS:-1800}
reset_unit=${RESET_UNIT:-forgejo-podman-store-reset.service}
reset_restart_file=${RESET_RESTART_FILE:-/run/forgejo-podman-store-reset/restart}
# shellcheck disable=SC1090
source "${DISK_HELPER_FILE:-$(dirname "${BASH_SOURCE[0]}")/disk-space-admission.sh}"

fail() {
  echo "$1" >&2
  exit 1
}
valid_unit() { [[ $1 =~ ^[A-Za-z0-9_.@-]+\.service$ ]]; }

for value in "$sample_seconds" "$max_iterations" "$start_retry_max_seconds" "$alert_interval_seconds" "$max_inactive_seconds"; do
  [[ $value =~ ^[0-9]+$ ]] || fail "invalid numeric setting"
done
[[ $game_enabled == 0 || $game_enabled == 1 ]] || fail "invalid game setting"
[[ $alert_enabled == 0 || $alert_enabled == 1 ]] || fail "invalid alert setting"
read -r -a runner_units <<<"$runner_units_text"
((${#runner_units[@]} > 0)) || fail "runner unit list is empty"
for unit in "${runner_units[@]}" "$game_unit" "$reset_unit"; do
  valid_unit "$unit" || fail "invalid unit name"
done
if ((alert_enabled == 1)); then
  [[ ${SLUG:-} =~ ^[a-z0-9-]+$ ]] || fail "invalid slug"
  [[ -n ${PING_BASE_FILE:-} ]] || fail "ping base file is not set"
fi

now() {
  local uptime rest
  IFS=' ' read -r uptime rest <"$uptime_file" || return 1
  [[ $uptime =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  printf '%s\n' "${uptime%%.*}"
}
report() {
  printf 'event=%s %s\n' "$1" "${2:-}" || true
}
query() { timeout --foreground 10s "$systemctl_bin" "$@"; }

# Sets load, enablement, active, sub and result of a unit.
unit_state() {
  local properties key value
  load=unknown enablement=unknown active=unknown sub=unknown result=unknown
  properties=$(query show --property=LoadState --property=UnitFileState \
    --property=ActiveState --property=SubState --property=Result "$1") || return 1
  while IFS='=' read -r key value; do
    case $key in
      LoadState) load=$value ;;
      UnitFileState) enablement=$value ;;
      ActiveState) active=$value ;;
      SubState) sub=$value ;;
      Result) result=$value ;;
    esac
  done <<<"$properties"
}
marker() { printf '%s/runners/%s/held\n' "$state_dir" "$1"; }

# Sets hold_reason, empty when the runners may run. A disk hold lasts until
# space is back above the recovery floors, across controller restarts.
disk_held_file=$state_dir/disk-held
hold_reasons() {
  local disk_status=0
  hold_reason=
  if ((game_enabled == 1)); then
    if ! query is-active --quiet "$game_unit"; then
      hold_reason=game_signal_unavailable
    elif [[ -e $game_file ]]; then
      hold_reason=game
    fi
  fi
  disk_space_status || disk_status=$?
  case $disk_status in
    0) rm -f -- "$disk_held_file" ;;
    1 | 4) : >"$disk_held_file" ;;
  esac
  if [[ -e $disk_held_file ]]; then
    hold_reason=${hold_reason:+$hold_reason,}disk_space
  fi
}

hold_runner() {
  local unit=$1 path
  unit_state "$unit" || {
    report runner_unreadable "runner_unit=$unit"
    return 0
  }
  case $active in
    active | activating | reloading) ;;
    *) return 0 ;;
  esac
  path=$(marker "$unit")
  mkdir -p "${path%/*}"
  : >"$path"
  if query --no-block stop "$unit"; then
    report runner_stop_requested "runner_unit=$unit reason=$hold_reason"
  else
    report runner_stop_failed "runner_unit=$unit reason=$hold_reason"
  fi
}

declare -A next_start=() start_delay=() inactive_since=()
release_runner() {
  local unit=$1 path current delay
  path=$(marker "$unit")
  [[ -e $path ]] || return 0
  unit_state "$unit" || {
    report runner_unreadable "runner_unit=$unit"
    return 0
  }
  # Once the start is past its conditions, systemd owns it, restarts
  # included, and the marker goes: a later operator stop then stays. While
  # the gate runs (SubState condition) it may still refuse and mark again.
  case $active:$sub in
    active:* | reloading:* | activating:start-pre | activating:start | activating:start-post | activating:auto-restart)
      rm -f -- "$path"
      unset "next_start[$unit]" "start_delay[$unit]"
      report runner_resumed "runner_unit=$unit active_state=$active sub_state=$sub"
      return 0
      ;;
    inactive:* | failed:*) ;;
    *) return 0 ;;
  esac
  if [[ $load != loaded || ($enablement != enabled && $enablement != enabled-runtime) ]]; then
    rm -f -- "$path"
    unset "next_start[$unit]" "start_delay[$unit]"
    report runner_release_skipped "runner_unit=$unit load_state=$load unit_file_state=$enablement"
    return 0
  fi
  current=$(now) || return 0
  ((current >= ${next_start[$unit]:-0})) || return 0
  delay=${start_delay[$unit]:-$sample_seconds}
  ((delay > 0)) || delay=1
  next_start[$unit]=$((current + delay))
  delay=$((delay * 2))
  ((delay <= start_retry_max_seconds)) || delay=$start_retry_max_seconds
  start_delay[$unit]=$delay
  # A stop that timed out, as on 2026-10-31, leaves the unit failed; the
  # controller owns that stop, so it clears the result before starting.
  if [[ $active == failed ]]; then
    query reset-failed "$unit" || true
  fi
  # The marker stays until the runner runs, so a start that is skipped or
  # lost is requested again.
  if query --no-block start "$unit"; then
    report runner_start_requested "runner_unit=$unit active_state=$active result=$result"
  else
    report runner_start_failed "runner_unit=$unit active_state=$active result=$result"
  fi
}

# The ping base is private: it goes to curl through its configuration on
# standard input, never on a command line.
send_ping() {
  local suffix=$1 body=$2 base url report=$state_dir/alert-report
  base="$(tr -d '\r\n' <"$PING_BASE_FILE")" || return 1
  [[ -n $base ]] || return 1
  url="$base/$SLUG$suffix?create=1"
  printf '%s' "$body" >"$report"
  printf 'url = "%s"\ndata-binary = "@%s"\n' "$url" "$report" |
    "$curl_bin" --config - --silent --show-error --fail --max-time 10 >/dev/null
}

# The reset lists the runners it stopped until it has started them again; the
# list counts only while the reset runs.
reset_held() {
  local unit=$1 state listed
  [[ -f $reset_restart_file && ! -L $reset_restart_file ]] || return 1
  state=$(query show --property=ActiveState --value "$reset_unit") || return 1
  [[ $state == activating || $state == deactivating ]] || return 1
  while IFS= read -r listed; do
    [[ $listed != "$unit" ]] || return 0
  done <"$reset_restart_file"
  return 1
}

next_alert=0
check_runners_left_off() {
  local unit current body="" issues=0 since cause
  current=$(now) || return 0
  ((current >= next_alert)) || return 0
  next_alert=$((current + alert_interval_seconds))
  for unit in "${runner_units[@]}"; do
    if ! unit_state "$unit"; then
      body+="$unit: systemd state is unreadable"$'\n'
      issues=$((issues + 1))
      continue
    fi
    case $active in
      active | reloading)
        unset "inactive_since[$unit]"
        continue
        ;;
    esac
    # After a hold, a marker excuses only a runner still draining its jobs:
    # one whose start keeps failing, is refused or crash-loops (activating
    # in auto-restart) counts from the release like any other.
    if [[ -n $hold_reason ]] || { [[ -e $(marker "$unit") ]] && [[ $active == deactivating ]]; } || reset_held "$unit"; then
      unset "inactive_since[$unit]"
      body+="$unit: held (${hold_reason:-marker or reset})"$'\n'
      continue
    fi
    since=${inactive_since[$unit]:-$current}
    inactive_since[$unit]=$since
    if ((current - since >= max_inactive_seconds)); then
      if [[ -e $(marker "$unit") ]]; then
        cause="its start after the hold has not succeeded"
      else
        cause="no hold reason or marker"
      fi
      body+="$unit: $active ($result) for $(((current - since) / 60))m, $cause"$'\n'
      issues=$((issues + 1))
      report runner_left_off "runner_unit=$unit active_state=$active result=$result minutes=$(((current - since) / 60))"
    fi
  done
  ((alert_enabled == 1)) || return 0
  if ((issues > 0)); then
    send_ping /fail "$body" || report ping_failed
  else
    send_ping "" "${body:-all runners admitting}" || report ping_failed
  fi
}

mkdir -p "$state_dir"
chmod 0700 "$state_dir"
for unit in "${runner_units[@]}"; do
  mkdir -p "$state_dir/runners/$unit"
done
if [[ ${DISK_SPACE_ENABLED:-0} == 1 && -n ${DISK_SPACE_VALUES_FILE:-} ]]; then
  exec 7<"$DISK_SPACE_VALUES_FILE"
  # The sourced disk helper reads this stream.
  # shellcheck disable=SC2034
  DISK_SPACE_STREAM=1
fi

previous="-"
iteration=0
while ((max_iterations == 0 || iteration < max_iterations)); do
  iteration=$((iteration + 1))
  hold_reasons
  if [[ $hold_reason != "$previous" ]]; then
    if [[ -n $hold_reason ]]; then
      report hold "reason=$hold_reason"
    elif [[ $previous != - ]]; then
      report release
    fi
    # Each hold or release starts the start spacing afresh.
    next_start=() start_delay=()
    previous=$hold_reason
  fi
  for unit in "${runner_units[@]}"; do
    if [[ -n $hold_reason ]]; then
      hold_runner "$unit"
    else
      release_runner "$unit"
    fi
  done
  check_runners_left_off
  if ((iteration == 1)); then
    "$notify_bin" --ready --status="holding runners: ${hold_reason:-none}" || true
  elif [[ $hold_reason != "${notified:-}" ]]; then
    "$notify_bin" --status="holding runners: ${hold_reason:-none}" || true
  fi
  notified=$hold_reason
  if ((max_iterations != 0 && iteration >= max_iterations)); then break; fi
  sleep "$sample_seconds"
done
