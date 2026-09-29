#!/usr/bin/env bash
# Shared root-filesystem admission sample for the aggregate guard and start gate.
# Status: 0 recovered, 1 below drain threshold, 2 below critical threshold,
# 3 between drain and recovery thresholds, 4 unreadable/invalid.
disk_space_status() {
  local size available
  if [[ ${DISK_SPACE_ENABLED:-0} != 1 ]]; then return 0; fi
  disk_free_bytes=unknown
  disk_free_percent=unknown
  if [[ -n ${DISK_SPACE_VALUES_FILE:-} ]]; then
    if [[ ${DISK_SPACE_STREAM:-0} == 1 ]]; then
      read -r size available <&7 || return 4
    else
      read -r size available < "$DISK_SPACE_VALUES_FILE" || return 4
    fi
  else
    read -r size available < <(
      timeout --foreground 5s df --block-size=1 --output=size,avail "${DISK_SPACE_PATH:-/}" |
        awk 'NR == 2 { print $1, $2 }'
    ) || return 4
  fi
  [[ $size =~ ^[1-9][0-9]*$ && $available =~ ^[0-9]+$ ]] || return 4
  ((available <= size)) || return 4
  # The aggregate guard reports this value from the sourced helper.
  # shellcheck disable=SC2034
  disk_free_bytes=$available
  disk_free_percent=$((available * 100 / size))
  if ((available < DISK_CRITICAL_BYTES || disk_free_percent < DISK_CRITICAL_PERCENT)); then return 2; fi
  if ((available < DISK_DRAIN_BYTES || disk_free_percent < DISK_DRAIN_PERCENT)); then return 1; fi
  if ((available >= DISK_RECOVERY_BYTES && disk_free_percent >= DISK_RECOVERY_PERCENT)); then return 0; fi
  return 3
}
