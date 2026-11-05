#!/usr/bin/env bash
set -euo pipefail

# nixfleet-runner-status: prints, without root and without changing anything,
# the state of this host's runners and of the other units nixfleet tracks
# (ADR-0041, nix-packages ADR-0017). `nixfleet status` runs it over SSH. One
# record per line, fields separated by tabs, "-" for an empty field:
#
#   version       1
#   hold          <ActiveState of the runner hold> <hold reason: none, game, ...>
#   restart-unit  <unit> <seconds it waits before it gives up>
#   restart       <ActiveState of the restart unit> <status> <unix time>
#                 <units, comma-separated> <reason>
#   unit          <runner|service> <unit> <ActiveState> <SubState>
#                 <restart: yes|no> <restart reason> <label names,
#                 comma-separated> <why a runner is not running>
#
# The restart line is absent before the restart unit first ran; its status is
# waiting, restarting, done, nothing, busy or failed.

# shellcheck disable=SC1090
source "${STATE_HELPER_FILE:-$(dirname "${BASH_SOURCE[0]}")/runner-state.sh}"

runners_text=${RUNNERS:-}
services_text=${SERVICES:-}
hold_unit=${HOLD_UNIT:-forgejo-runner-hold.service}
reset_unit=${RESET_UNIT:-}
restart_unit=${RESTART_UNIT:-forgejo-runner-restart.service}
restart_wait_seconds=${RESTART_WAIT_SECONDS:-3600}
restart_state_file=${RESTART_STATE_FILE:-/run/nixfleet-runners/restart}

field() {
  local value=${1//$'\t'/ }
  value=${value//$'\n'/ }
  printf '%s' "${value:--}"
}
line() {
  local first=1 value
  for value in "$@"; do
    ((first == 1)) || printf '\t'
    field "$value"
    first=0
  done
  printf '\n'
}

printf 'version\t1\n'
hold_state "$hold_unit"
line hold "$hold_active" "$hold_reason"
reset_running=0
if [[ -n $reset_unit ]]; then
  reset_active=$(query show --property=ActiveState --value "$reset_unit" 2>/dev/null) || reset_active=unknown
  [[ $reset_active != activating && $reset_active != deactivating ]] || reset_running=1
fi

line restart-unit "$restart_unit" "$restart_wait_seconds"
if [[ -f $restart_state_file ]]; then
  restart_active=$(query show --property=ActiveState --value "$restart_unit" 2>/dev/null) || restart_active=unknown
  status="" time="" units="" reason=""
  while IFS='=' read -r key value; do
    case $key in
      status) status=$value ;;
      time) time=$value ;;
      unit) units+=${units:+,}$value ;;
      reason) reason=$value ;;
    esac
  done <"$restart_state_file"
  # A run killed by its timeout cannot write its result. A state that could
  # not be read may belong to a live run, so it is reported as written.
  case $restart_active:$status in
    activating:* | deactivating:* | unknown:*) ;;
    *:waiting | *:restarting)
      reason="the restart unit ended ($restart_active) without a result, last: $status ${reason:-}"
      status=failed
      ;;
  esac
  line restart "$restart_active" "$status" "$time" "$units" "$reason"
fi

report_unit() {
  local kind=$1 unit=$2 labels=$3 restart=no reason
  if ! valid_unit "$unit" || ! unit_state "$unit"; then
    line unit "$kind" "$unit" unknown unknown no "" "$labels" "systemd state is unreadable"
    return 0
  fi
  if restart_needed "$unit"; then restart=yes; fi
  if [[ $kind == runner ]]; then
    reason=$(inactive_reason "$reset_running")
  else
    case $active in
      active | reloading) reason="" ;;
      *) reason="$active ($result)" ;;
    esac
  fi
  line unit "$kind" "$unit" "$active" "$sub" "$restart" "$restart_reason" "$labels" "$reason"
}

# RUNNERS is "<unit>=<label names, comma-separated>" per runner, SERVICES the
# other tracked units, both separated by spaces.
for entry in $runners_text; do
  report_unit runner "${entry%%=*}" "${entry#*=}"
done
for unit in $services_text; do
  report_unit service "$unit" ""
done
