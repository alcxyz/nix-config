#!/usr/bin/env bash

# Watch for system resume (PrepareForSleep=false) and restart DMS
# to fix layer surfaces (OSD overlays) not surviving sleep cycles.

dbus-monitor --system \
  "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" 2>/dev/null |
while read -r line; do
  if echo "$line" | grep -q "boolean false"; then
    sleep 2
    pkill -f "dms run" 2>/dev/null || true
    sleep 1
    dms run &
  fi
done
