# shellcheck shell=bash
# The functions set variables for the scripts that source this file.
# shellcheck disable=SC2034
# What nixfleet and the restart unit know about a runner unit (ADR-0041,
# nix-packages ADR-0017), sourced by runner-record.sh, runner-status.sh and
# runner-restart.sh. Everything here reads systemd and the start records
# without root.
#
# A unit with restartIfChanged = false keeps running the definition it was
# started with after a switch. At each start runner-record.sh records the
# invocation and the resolved store paths of the unit file and its drop-ins;
# a running unit whose record is missing, belongs to another invocation or
# names other paths than the deployed ones needs a restart.

record_dir=${RECORD_DIR:-/run/nixfleet-runners/started}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
readlink_bin=${READLINK_BIN:-readlink}

valid_unit() { [[ $1 =~ ^[A-Za-z0-9_.@-]+\.service$ ]]; }
query() { timeout -k 2s 10s "$systemctl_bin" "$@"; }

# Prints the definition of a unit: its resolved unit file, then its resolved
# drop-ins, separated by single spaces. A path that does not resolve is kept.
unit_definition() {
  local fragment=$1 drop_ins=$2 resolved path definition
  definition=$("$readlink_bin" -f -- "$fragment" 2>/dev/null) || definition=$fragment
  for path in $drop_ins; do
    resolved=$("$readlink_bin" -f -- "$path" 2>/dev/null) || resolved=$path
    definition+=" $resolved"
  done
  printf '%s\n' "$definition"
}

# Sets enablement, active, sub, result, invocation and definition of a unit.
unit_state() {
  local properties key value fragment="" drop_ins=""
  enablement=unknown active=unknown sub=unknown result=unknown invocation=""
  properties=$(query show --property=UnitFileState \
    --property=ActiveState --property=SubState --property=Result \
    --property=InvocationID --property=FragmentPath --property=DropInPaths "$1") || return 1
  while IFS='=' read -r key value; do
    case $key in
      UnitFileState) enablement=$value ;;
      ActiveState) active=$value ;;
      SubState) sub=$value ;;
      Result) result=$value ;;
      InvocationID) invocation=$value ;;
      FragmentPath) fragment=$value ;;
      DropInPaths) drop_ins=$value ;;
    esac
  done <<<"$properties"
  definition=$(unit_definition "$fragment" "$drop_ins")
}

# After unit_state, succeeds when the running unit needs a restart and sets
# restart_reason. A unit that does not run gets the deployed definition at its
# next start, so it never needs one.
restart_needed() {
  local unit=$1 key value recorded_invocation="" recorded_definition="" record
  restart_reason=""
  case $active in
    active | reloading) ;;
    *) return 1 ;;
  esac
  record=$record_dir/$unit
  if [[ ! -f $record ]]; then
    restart_reason="no start record"
    return 0
  fi
  while IFS='=' read -r key value; do
    case $key in
      invocation) recorded_invocation=$value ;;
      definition) recorded_definition=$value ;;
    esac
  done <"$record"
  if [[ -z $invocation || $recorded_invocation != "$invocation" ]]; then
    restart_reason="no start record"
    return 0
  fi
  if [[ $recorded_definition != "$definition" ]]; then
    restart_reason="started from an older definition"
    return 0
  fi
  return 1
}

# Sets hold_active and hold_reason from the runner hold's status text:
# "holding runners: <reason>", where none means no reason applies.
hold_state() {
  local properties key value text=""
  hold_active=unknown hold_reason=unknown
  properties=$(query show --property=ActiveState --property=StatusText "$1") || return 0
  while IFS='=' read -r key value; do
    case $key in
      ActiveState) hold_active=$value ;;
      StatusText) text=$value ;;
    esac
  done <<<"$properties"
  if [[ $hold_active == active && $text == "holding runners: "* ]]; then
    hold_reason=${text#holding runners: }
  fi
}

# After unit_state and hold_state, prints why a runner is not running, or
# nothing for one that runs. The argument is 1 while the Podman store reset
# runs.
inactive_reason() {
  local reset_running=${1:-0} reason
  case $active:$sub in
    active:* | reloading:*) return 0 ;;
    activating:auto-restart) reason="restarting after a failure ($result)" ;;
    activating:condition) reason="its start gate is checking" ;;
    activating:*) reason=starting ;;
    deactivating:*) reason="stopping; its running jobs finish first" ;;
    *)
      if [[ $enablement == masked || $enablement == disabled ]]; then
        reason="$enablement; nothing starts it"
      elif ((reset_running == 1)); then
        reason="stopped while the Podman store reset runs, which starts again the runners it stopped"
      elif [[ $hold_reason != none && $hold_reason != unknown ]]; then
        reason="held by the runner hold ($hold_reason); it starts when that ends"
      elif [[ $result == exec-condition ]]; then
        reason="its start gate refused the last start; the runner hold retries a held runner"
      elif [[ $active == failed ]]; then
        reason="failed ($result)"
      else
        reason="stopped by hand or by a reboot run; nothing starts it again"
      fi
      if [[ $hold_active != active ]]; then
        reason+="; the runner hold is $hold_active"
      fi
      ;;
  esac
  printf '%s\n' "$reason"
}
