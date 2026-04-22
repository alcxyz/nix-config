#!/usr/bin/env bash

# Restart DMS after display wakes from DPMS sleep to restore OSD overlays.
#
# Strategy: watch Hyprland socket2 for closelayer>>dms:bar (reliable
# signal that the display went to DPMS sleep), then poll hyprctl for
# dpmsStatus returning to true.  This avoids the chicken-and-egg problem
# of the old approach, which waited for openlayer>>dms:bar — an event
# that never fires when DMS is broken after wake.

SOCKET="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
COOLDOWN=10  # seconds to ignore closelayer after a restart
last_restart=0

restart_dms() {
  pkill -f "dms run" 2>/dev/null || true
  sleep 1
  dms run &
  last_restart=$(date +%s)
}

wait_for_dpms_on() {
  while true; do
    sleep 2
    dpms=$(hyprctl monitors -j | jq -r '.[0].dpmsStatus' 2>/dev/null)
    if [[ "$dpms" == "true" ]]; then
      return
    fi
  done
}

while true; do
  while IFS= read -r line; do
    case "$line" in
      "closelayer>>dms:bar")
        now=$(date +%s)
        if (( now - last_restart < COOLDOWN )); then
          # Ignore closelayer fired by our own pkill.
          continue
        fi
        # Display went to sleep — poll until DPMS comes back on, then restart.
        wait_for_dpms_on
        sleep 2
        restart_dms
        ;;
    esac
  done < <(socat -U - UNIX-CONNECT:"$SOCKET" 2>/dev/null)
  # socat exited (socket temporarily unavailable) — retry
  sleep 3
done
