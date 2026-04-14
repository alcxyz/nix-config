#!/usr/bin/env bash

# Watch for monitor DPMS wake events and restart DMS
# to fix layer surfaces (OSD overlays) not surviving display sleep.
#
# Uses Hyprland's socket2 event stream which emits dpms>>on,MONITORNAME
# when a monitor wakes from DPMS sleep. This covers both idle-timeout
# display sleep and wake-from-system-suspend scenarios.
# (PrepareForSleep D-Bus signal is NOT emitted for plain DPMS sleep.)

SOCKET="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

while true; do
  socat -U - UNIX-CONNECT:"$SOCKET" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      dpms\>\>on*)
        sleep 2
        pkill -f "dms run" 2>/dev/null || true
        sleep 1
        dms run &
        ;;
    esac
  done
  # If socat exits (e.g. socket briefly unavailable after system resume), retry
  sleep 3
done
