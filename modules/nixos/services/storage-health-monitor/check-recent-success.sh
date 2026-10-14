#!/usr/bin/env bash
set -euo pipefail

if (($# != 5 && $# != 6)); then
  echo 'usage: check-recent-success UNIT MAXIMUM_AGE ALLOW_PENDING_FIRST_TIMER MARKER UPTIME_FILE [PENDING_FIRST_TIMER_MAXIMUM_AGE]' >&2
  exit 2
fi

unit=$1
maximum_age=$2
allow_pending_first_timer=$3
marker=$4
uptime_file=$5
pending_first_timer_maximum_age=${6:-$maximum_age}
pending_timer_command=${STORAGE_HEALTH_PENDING_TIMER:-storage-health-check-pending-first-timer}
systemctl_command=${STORAGE_HEALTH_SYSTEMCTL:-systemctl}
date_command=${STORAGE_HEALTH_DATE:-date}

read_property() {
  "$systemctl_command" show "$unit" -p "$1" --value 2>/dev/null
}

if ! result=$(read_property Result) ||
  ! code=$(read_property ExecMainCode) ||
  ! status=$(read_property ExecMainStatus) ||
  ! finished=$(read_property InactiveEnterTimestampMonotonic); then
  printf '%s: current unit state is unavailable\n' "$unit"
  exit 1
fi

if [[ -z $result || ! $code =~ ^[0-9]{1,9}$ || ! $status =~ ^[0-9]{1,9}$ ||
  ! $finished =~ ^[0-9]{1,18}$ ]]; then
  printf '%s: current unit state is malformed\n' "$unit"
  exit 1
fi
if [[ $result != success ]] || ((code != 0 && code != 1)) || ((status != 0)); then
  printf '%s: last result is %s with code %s and status %s\n' \
    "$unit" "$result" "$code" "$status"
  exit 1
fi

failure_reason='no successful completion timestamp'
if [[ -e $marker || -L $marker ]]; then
  if [[ ! -f $marker || ! -r $marker ]]; then
    printf '%s: durable successful completion timestamp is unavailable\n' "$unit"
    exit 1
  fi
  mapfile -t marker_lines <"$marker"
  if ((${#marker_lines[@]} != 1)) ||
    [[ ! ${marker_lines[0]:-} =~ ^[1-9][0-9]{0,17}$ ]]; then
    printf '%s: durable successful completion timestamp is malformed\n' "$unit"
    exit 1
  fi
  successful_at=${marker_lines[0]}
  now=$("$date_command" +%s)
  if [[ ! $now =~ ^[1-9][0-9]{0,17}$ ]]; then
    printf '%s: current wall-clock timestamp is unavailable\n' "$unit"
    exit 1
  fi
  if ((10#$successful_at > 10#$now)); then
    printf '%s: durable successful completion timestamp is in the future\n' "$unit"
    exit 1
  fi
  age=$((10#$now - 10#$successful_at))
  if ((age <= maximum_age)); then
    exit 0
  fi
  failure_reason="last successful completion is $age seconds old"
elif [[ $result == success && $code == 1 && $status == 0 &&
  $finished =~ ^[0-9]+$ ]] && ((finished > 0)); then
  now=$(awk '{printf "%.0f", $1 * 1000000}' "$uptime_file")
  if [[ ! $now =~ ^[0-9]+$ ]] || ((finished > now)); then
    printf '%s: current-boot successful completion timestamp is invalid\n' "$unit"
    exit 1
  fi
  age=$(((now - finished) / 1000000))
  if ((age > maximum_age)); then
    printf '%s: last successful completion is %s seconds old\n' "$unit" "$age"
    exit 1
  fi
  exit 0
fi

if [[ $allow_pending_first_timer == true && $code == 0 ]] &&
  "$pending_timer_command" "$unit" "$pending_first_timer_maximum_age"; then
  exit 0
fi

printf '%s: %s\n' "$unit" "$failure_reason"
exit 1
