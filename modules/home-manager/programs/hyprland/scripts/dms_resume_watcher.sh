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
EXTERNAL_LOCK_FILE="$STATE_DIR/external-lock"
LOG_TAG="dms-resume-watcher"
COOLDOWN=10
LOCK_SETTLE=3
LAYER_CHECKS=5

last_restart=0

mkdir -p "$STATE_DIR"

log() {
  logger -t "$LOG_TAG" -- "$*"
}

mark_armed() {
  : >"$ARM_FILE"
  if external_lock_active; then
    : >"$EXTERNAL_LOCK_FILE"
  fi
}

monitor_awake() {
  hyprctl monitors -j 2>/dev/null |
    jq -e 'length > 0 and any(.[]; (.disabled | not) and .dpmsStatus == true)' >/dev/null
}

external_lock_active() {
  pgrep -u "$(id -u)" -x hyprlock >/dev/null 2>&1
}

wait_for_stable_wake() {
  local checks=0

  while ((checks < 2)); do
    sleep 1
    if monitor_awake; then
      ((checks++))
    else
      checks=0
    fi
  done
}

wait_for_external_lock_release() {
  while external_lock_active; do
    sleep 1
  done

  sleep "$LOCK_SETTLE"
}

dms_layers_present() {
  hyprctl layers -j 2>/dev/null |
    jq -e '[.. | objects | .namespace? // empty | select(startswith("dms:"))] | length > 0' >/dev/null
}

wait_for_dms_layers() {
  local checks=0

  while ((checks < LAYER_CHECKS)); do
    if dms_layers_present; then
      return 0
    fi
    sleep 1
    ((checks++))
  done

  return 1
}

restart_dms() {
  log "restarting DMS after display wake"
  if ! systemctl --user restart dms.service; then
    log "failed to restart the systemd-managed DMS service"
    return 1
  fi
  last_restart=$(date +%s)
}

watch_socket() {
  while true; do
    while IFS= read -r line; do
      case "$line" in
        dpms\>\>off* | monitorremoved\>\>*)
          mark_armed
          ;;
        "closelayer>>dms:bar")
          if ! monitor_awake; then
            mark_armed
          fi
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
external_lock=0

while true; do
  if [[ -e "$ARM_FILE" ]]; then
    armed=1
    rm -f "$ARM_FILE"
  fi

  if [[ -e "$EXTERNAL_LOCK_FILE" ]]; then
    external_lock=1
    rm -f "$EXTERNAL_LOCK_FILE"
  fi

  if ! monitor_awake; then
    armed=1
    if external_lock_active; then
      external_lock=1
    fi
    sleep 2
    continue
  fi

  if ((armed)); then
    now=$(date +%s)
    if ((now - last_restart >= COOLDOWN)); then
      wait_for_stable_wake
      if ((external_lock)); then
        wait_for_external_lock_release
        if wait_for_dms_layers; then
          log "DMS layers present after external lock wake; skipping restart"
        else
          restart_dms
        fi
      else
        restart_dms
      fi
    fi
    armed=0
    external_lock=0
  fi

  sleep 2
done
