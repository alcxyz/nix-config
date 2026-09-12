#!/usr/bin/env bash
set -euo pipefail

if (($# != 2)); then
  echo 'usage: check-active-unit UNIT MODE' >&2
  exit 2
fi

unit=$1
mode=$2
systemctl_command=${STORAGE_HEALTH_SYSTEMCTL:-systemctl}

if [[ $mode != active && $mode != active-not-degraded ]]; then
  printf '%s: unsupported active-unit mode %s\n' "$unit" "$mode"
  exit 2
fi

if [[ $("$systemctl_command" is-active "$unit" 2>/dev/null || true) != active ]]; then
  printf '%s: required service is not active\n' "$unit"
  exit 1
fi

if [[ $mode == active ]]; then
  exit 0
fi

if ! status=$("$systemctl_command" show "$unit" -p StatusText --value 2>/dev/null); then
  printf '%s: service status is unavailable\n' "$unit"
  exit 1
fi
if [[ -z $status || $status == *$'\n'* ]]; then
  printf '%s: service status is empty or malformed\n' "$unit"
  exit 1
fi
if [[ $status == degraded:* ]]; then
  printf '%s: %s\n' "$unit" "$status"
  exit 1
fi
