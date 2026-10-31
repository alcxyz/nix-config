#!/usr/bin/env bash
# Shared free-space sample for the runner hold and the start gate.
# Status: 0 recovered, 1 below the drain floor, 3 between the drain and
# recovery floors, 4 unreadable or invalid.
disk_space_status() {
  local size available
  if [[ ${DISK_SPACE_ENABLED:-0} != 1 ]]; then return 0; fi
  disk_free_bytes=unknown
  disk_free_percent=unknown
  if [[ -n ${DISK_SPACE_VALUES_FILE:-} ]]; then
    if [[ ${DISK_SPACE_STREAM:-0} == 1 ]]; then
      read -r size available <&7 || return 4
    else
      read -r size available <"$DISK_SPACE_VALUES_FILE" || return 4
    fi
  else
    read -r size available < <(
      timeout --foreground 5s df --block-size=1 --output=size,avail "${DISK_SPACE_PATH:-/}" |
        awk 'NR == 2 { print $1, $2 }'
    ) || return 4
  fi
  [[ $size =~ ^[1-9][0-9]*$ && $available =~ ^[0-9]+$ ]] || return 4
  ((available <= size)) || return 4
  # Callers report these values.
  # shellcheck disable=SC2034
  disk_free_bytes=$available
  disk_free_percent=$((available * 100 / size))
  if ((available < DISK_DRAIN_BYTES || disk_free_percent < DISK_DRAIN_PERCENT)); then return 1; fi
  if ((available >= DISK_RECOVERY_BYTES && disk_free_percent >= DISK_RECOVERY_PERCENT)); then return 0; fi
  return 3
}
