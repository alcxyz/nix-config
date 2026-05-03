#!/usr/bin/env bash

# Restart DMS after display wake to restore layer-shell overlays.
#
# Hyprland/DMS has failed in a few different ways after monitor sleep:
# sometimes socket2 emits dpms events, sometimes the reliable symptom is
# closelayer>>dms:bar, and sometimes the overlay simply never reopens.
# Treat sleep/wake as state from hyprctl instead of relying on one event.

SOCKET="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
STATE_DIR="$XDG_RUNTIME_DIR/dms-resume-watcher"
ARM_FILE="$STATE_DIR/armed"
LOG_TAG="dms-resume-watcher"
COOLDOWN=10

last_restart=0

mkdir -p "$STATE_DIR"

log() {
  logger -t "$LOG_TAG" -- "$*"
}

mark_armed() {
  : > "$ARM_FILE"
}

monitor_awake() {
  hyprctl monitors -j 2>/dev/null |
    jq -e 'length > 0 and any(.[]; (.disabled | not) and .dpmsStatus == true)' >/dev/null
}

wait_for_stable_wake() {
  local checks=0

  while (( checks < 2 )); do
    sleep 1
    if monitor_awake; then
      ((checks++))
    else
      checks=0
    fi
  done
}

restart_dms() {
  log "restarting DMS after display wake"
  dms kill >/dev/null 2>&1 || true
  pkill -f '(^|/)dms( .*)? run' 2>/dev/null || true
  sleep 1
  setsid -f dms run >/tmp/dms-resume-watcher.log 2>&1
  last_restart=$(date +%s)
}

watch_socket() {
  while true; do
    while IFS= read -r line; do
      case "$line" in
        dpms\>\>off* | monitorremoved\>\>* | "closelayer>>dms:bar")
          mark_armed
          ;;
      esac
    done < <(socat -U - UNIX-CONNECT:"$SOCKET" 2>/dev/null)

    sleep 3
  done
}

watch_socket &
socket_watcher_pid=$!
trap 'kill "$socket_watcher_pid" 2>/dev/null || true' EXIT

armed=0

while true; do
  if [[ -e "$ARM_FILE" ]]; then
    armed=1
    rm -f "$ARM_FILE"
  fi

  if ! monitor_awake; then
    armed=1
    sleep 2
    continue
  fi

  if (( armed )); then
    now=$(date +%s)
    if (( now - last_restart >= COOLDOWN )); then
      wait_for_stable_wake
      restart_dms
    fi
    armed=0
  fi

  sleep 2
done
