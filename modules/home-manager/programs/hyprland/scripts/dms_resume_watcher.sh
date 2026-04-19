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
#
# post_restart guards against the self-inflicted restart loop: when we
# pkill DMS, the dying process fires closelayer>>dms:bar into the
# socat buffer. Without the guard, that buffered close sets went_to_sleep=1,
# the new DMS's openlayer immediately triggers another pkill, and so on.

SOCKET="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

went_to_sleep=0
post_restart=0

while true; do
  while IFS= read -r line; do
    case "$line" in
      "closelayer>>dms:bar")
        if [[ $post_restart -eq 1 ]]; then
          # Ignore the closelayer emitted by the DMS instance we just killed.
          post_restart=0
        else
          went_to_sleep=1
        fi
        ;;
      "openlayer>>dms:bar")
        if [[ $went_to_sleep -eq 1 ]]; then
          went_to_sleep=0
          sleep 2
          post_restart=1
          pkill -f "dms run" 2>/dev/null || true
          sleep 1
          dms run &
        fi
        ;;
    esac
  done < <(socat -U - UNIX-CONNECT:"$SOCKET" 2>/dev/null)
  # socat exited (socket temporarily unavailable) — reset state and retry
  went_to_sleep=0
  post_restart=0
  sleep 3
done
