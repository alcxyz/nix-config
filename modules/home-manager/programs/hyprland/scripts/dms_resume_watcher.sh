#!/usr/bin/env bash

# Restart DMS after display wakes from DPMS sleep to restore OSD overlays.
#
# Hyprland does NOT emit dpms>> events on socket2. Instead, it emits
# closelayer>>dms:bar when the display sleeps and openlayer>>dms:bar
# when it wakes. We use a state machine to avoid restarting on initial
# DMS startup (which also fires openlayer>>dms:bar).
#
# Uses process substitution (< <(...)) instead of a pipe so the while
# loop runs in the main shell and the went_to_sleep variable persists.

SOCKET="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

went_to_sleep=0

while true; do
  while IFS= read -r line; do
    case "$line" in
      "closelayer>>dms:bar")
        went_to_sleep=1
        ;;
      "openlayer>>dms:bar")
        if [[ $went_to_sleep -eq 1 ]]; then
          went_to_sleep=0
          sleep 2
          pkill -f "dms run" 2>/dev/null || true
          sleep 1
          dms run &
        fi
        ;;
    esac
  done < <(socat -U - UNIX-CONNECT:"$SOCKET" 2>/dev/null)
  # socat exited (socket temporarily unavailable) — reset state and retry
  went_to_sleep=0
  sleep 3
done
