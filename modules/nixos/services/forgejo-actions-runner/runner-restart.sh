#!/usr/bin/env bash
set -euo pipefail

# forgejo-runner-restart (ADR-0041, nix-packages ADR-0017): restarts the
# runner units, engine APIs and resource policy that still run an older
# definition, once their running jobs finish. These units have
# restartIfChanged = false, so a switch leaves them running.
#
# It pauses the runners the restart touches: the flagged ones, or all of them
# when an API or the resource policy is flagged, since restarting those also
# restarts the runners that require them. A paused runner takes no new job,
# lets its running ones finish, and reports "paused tasks=<running>" as its
# status text. Once each reports no tasks, nothing runs that the restart could
# cut short. The pauses stay until the restarted units have been checked, so a
# restarted runner cannot take a job early, and end when this script exits; the
# unit's ExecStopPost removes them if it is killed.
#
# It waits for a Podman store reset or a runner's start or stop to end first.
# At the wait limit it gives up and reports busy, so it never cancels a job on
# purpose. A running runner that has not reported the pause
# within the acknowledgement limit runs a build that cannot pause, which fails
# the run; a plain systemctl restart is the way through for such a runner.
#
# Its progress and result go to a world-readable state file that
# nixfleet-runner-status reports: status=waiting|restarting|done|nothing|busy|
# failed, time=<unix seconds>, one unit= line per unit it restarts or would,
# and reason=.

# shellcheck disable=SC1090
source "${STATE_HELPER_FILE:-$(dirname "${BASH_SOURCE[0]}")/runner-state.sh}"

state_file=${STATE_FILE:-/run/nixfleet-runners/restart}
pause_dir=${PAUSE_DIR:-/run/nixfleet-runners/paused}
date_bin=${DATE_BIN:-date}
sleep_bin=${SLEEP_BIN:-sleep}
runner_units_text=${RUNNER_UNITS:-}
service_units_text=${SERVICE_UNITS:-}
reset_unit=${RESET_UNIT:-}
wait_seconds=${WAIT_SECONDS:-3900}
ack_seconds=${ACK_SECONDS:-60}
poll_seconds=${POLL_SECONDS:-10}
restart_timeout_seconds=${RESTART_TIMEOUT_SECONDS:-4200}

terminal=0
fail() {
  echo "$1" >&2
  exit 1
}

now() { "$date_bin" +%s; }

# A run that ends without a result (an invalid setting, a failed read) says
# so, rather than leaving an earlier run's result or waiting behind. The trap
# is set before the settings are checked.
on_exit() {
  local status=$?
  if ((terminal == 0)); then
    terminal=1
    write_state failed "ended with status $status before a result" || true
  fi
  rm -f -- "${pause_dir:?}"/*.service
}

flagged=()
write_state() {
  local status=$1 reason=${2:-} tmp unit
  install -d -m 0755 -- "${state_file%/*}"
  tmp=$(mktemp "${state_file%/*}/.restart.XXXXXX")
  {
    printf 'status=%s\ntime=%s\n' "$status" "$(now)"
    for unit in "${flagged[@]}"; do
      printf 'unit=%s\n' "$unit"
    done
    printf 'reason=%s\n' "${reason//$'\n'/ }"
  } >"$tmp"
  chmod 0644 -- "$tmp"
  mv -f -- "$tmp" "$state_file"
  printf 'event=%s units=%s reason=%s\n' "$status" "${flagged[*]:-none}" "${reason:-none}"
  case $status in
    done | nothing | busy | failed) terminal=1 ;;
  esac
}
trap on_exit EXIT

for value in "$wait_seconds" "$ack_seconds" "$poll_seconds" "$restart_timeout_seconds"; do
  [[ $value =~ ^[0-9]+$ ]] || fail "invalid numeric setting"
done
read -r -a runner_units <<<"$runner_units_text"
read -r -a service_units <<<"$service_units_text"
((${#runner_units[@]} > 0)) || fail "runner unit list is empty"
for unit in "${runner_units[@]}" "${service_units[@]}"; do
  valid_unit "$unit" || fail "invalid unit name"
done
[[ -z $reset_unit ]] || valid_unit "$reset_unit" || fail "invalid unit name"

# Sets flagged to the tracked units that need a restart.
find_flagged() {
  local unit
  flagged=()
  for unit in "${runner_units[@]}" "${service_units[@]}"; do
    unit_state "$unit" || fail "cannot read unit $unit"
    if restart_needed "$unit"; then
      flagged+=("$unit")
    fi
  done
}

# Succeeds while a store reset runs or a runner starts or stops; sets
# busy_reason.
in_transition() {
  local unit state
  busy_reason=""
  if [[ -n $reset_unit ]]; then
    state=$(query show --property=ActiveState --value "$reset_unit") || state=unknown
    case $state in
      activating | deactivating | unknown)
        busy_reason="store_reset_running"
        return 0
        ;;
    esac
  fi
  for unit in "${runner_units[@]}"; do
    unit_state "$unit" || {
      busy_reason="runner_unreadable unit=$unit"
      return 0
    }
    # A runner waiting to restart after a failure (auto-restart) runs no
    # job, and its next start takes the deployed definition anyway.
    case $active:$sub in
      activating:auto-restart) ;;
      activating:* | deactivating:*)
        busy_reason="runner_transition unit=$unit state=$active:$sub"
        return 0
        ;;
    esac
  done
  return 1
}

# Pauses the runners the flagged units touch. Pauses only ever get added: a unit
# flagged while waiting joins the same restart.
pause_runners() {
  local unit service
  to_pause=("${runner_units[@]}")
  for service in "${service_units[@]}"; do
    for unit in "${flagged[@]}"; do
      [[ $unit != "$service" ]] || return 0
    done
  done
  to_pause=()
  for unit in "${runner_units[@]}"; do
    if [[ -e $pause_dir/$unit ]] || [[ " ${flagged[*]} " == *" $unit "* ]]; then
      to_pause+=("$unit")
    fi
  done
}

declare -A unacknowledged_since=()
# Succeeds while a paused runner still has work or has not reported the pause;
# sets busy_reason. A runner that does not run has no job to wait for.
paused_runners_busy() {
  local unit text current since
  busy_reason=""
  for unit in "${to_pause[@]}"; do
    unit_state "$unit" || {
      busy_reason="runner_unreadable unit=$unit"
      return 0
    }
    case $active in
      active | reloading) ;;
      *)
        unset "unacknowledged_since[$unit]"
        continue
        ;;
    esac
    text=$(query show --property=StatusText --value "$unit") || text=""
    case $text in
      "paused tasks=0")
        unset "unacknowledged_since[$unit]"
        ;;
      "paused tasks="*)
        unset "unacknowledged_since[$unit]"
        [[ -n $busy_reason ]] || busy_reason="job_running unit=$unit"
        ;;
      *)
        current=$(now)
        since=${unacknowledged_since[$unit]:-$current}
        unacknowledged_since[$unit]=$since
        if ((current - since >= ack_seconds)); then
          write_state failed "$unit did not report the pause, so it runs a build that cannot pause; restart it with systemctl restart"
          exit 1
        fi
        [[ -n $busy_reason ]] || busy_reason="pausing unit=$unit"
        ;;
    esac
  done
  [[ -n $busy_reason ]]
}

deadline=$(($(now) + wait_seconds))
last_reason=""
while :; do
  find_flagged
  if ((${#flagged[@]} == 0)); then
    write_state nothing
    exit 0
  fi
  # A runner that starts or stops has not had the chance to report a pause.
  if in_transition; then
    unacknowledged_since=()
  else
    pause_runners
    install -d -m 0755 -- "$pause_dir"
    for unit in "${to_pause[@]}"; do
      : >"$pause_dir/$unit"
    done
    paused_runners_busy || break
  fi
  if (($(now) >= deadline)); then
    write_state busy "$busy_reason"
    exit 0
  fi
  if [[ $busy_reason != "$last_reason" ]]; then
    write_state waiting "$busy_reason"
    last_reason=$busy_reason
  fi
  "$sleep_bin" "$poll_seconds"
done

write_state restarting
status=0
timeout -k 5s "${restart_timeout_seconds}s" "$systemctl_bin" restart "${flagged[@]}" || status=$?
restarted=("${flagged[@]}")
if ((status != 0)); then
  write_state failed "systemctl restart exited with status $status"
  exit 1
fi
# A restarted unit that runs must have recorded its new start. One whose
# start gate refused the start (a hold began) does not run, and the runner
# hold starts it later with the deployed definition.
find_flagged
if ((${#flagged[@]} > 0)); then
  write_state failed "still not running the deployed definition after the restart"
  exit 1
fi
flagged=("${restarted[@]}")
write_state "done"
