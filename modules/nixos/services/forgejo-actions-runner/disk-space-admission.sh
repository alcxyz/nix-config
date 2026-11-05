#!/usr/bin/env bash
# Shared free-space sample for the runner hold and the start gate.
# Status: 0 recovered, 1 below the drain floor, 3 between the drain and
# recovery floors, 4 unreadable or invalid. With several paths the worst decides.
disk_space_judge() {
  local size=$1 available=$2
  [[ $size =~ ^[1-9][0-9]*$ && $available =~ ^[0-9]+$ ]] || return 4
  ((available <= size)) || return 4
  local free_percent=$((available * 100 / size))
  if ((available < DISK_DRAIN_BYTES || free_percent < DISK_DRAIN_PERCENT)); then return 1; fi
  if ((available >= DISK_RECOVERY_BYTES && free_percent >= DISK_RECOVERY_PERCENT)); then return 0; fi
  return 3
}

disk_space_status() {
  local size available path status worst=0
  local -a paths extra_paths
  if [[ ${DISK_SPACE_ENABLED:-0} != 1 ]]; then return 0; fi
  if [[ -n ${DISK_SPACE_VALUES_FILE:-} ]]; then
    if [[ ${DISK_SPACE_STREAM:-0} == 1 ]]; then
      read -r size available <&7 || return 4
    else
      read -r size available <"$DISK_SPACE_VALUES_FILE" || return 4
    fi
    disk_space_judge "$size" "$available"
    return
  fi
  read -ra extra_paths <<<"${DISK_SPACE_EXTRA_PATHS:-}"
  paths=("${DISK_SPACE_PATH:-/}" "${extra_paths[@]}")
  for path in "${paths[@]}"; do
    read -r size available < <(
      timeout --foreground 5s df --block-size=1 --output=size,avail "$path" |
        awk 'NR == 2 { print $1, $2 }'
    ) || return 4
    status=0
    disk_space_judge "$size" "$available" || status=$?
    if ((status == 1 || status == 4)); then return "$status"; fi
    if ((status == 3)); then worst=3; fi
  done
  return "$worst"
}
