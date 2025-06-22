#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="gamescope-stream"
LOG_PREFIX="[$SCRIPT_NAME]"

log() {
    echo "$LOG_PREFIX $1" >&2
}

ensure-game-sink

log "Starting HEADLESS Gamescope session for streaming..."

# We launch Gamescope in a window (-W, -H) but NOT fullscreen (-f) or borderless (-b).
# We tell Steam to use the old VGUI Big Picture mode, which is more compatible
# with being run inside another compositor and avoids the nested Gamescope problem.
exec mangohud gamescope \
    --backend=wayland \
    --expose-wayland \
    --force-grab-cursor \
    -W 2560 -H 1440 \
    -w 2560 -h 1440 \
    -r 60 \
    -- flatpak run com.valvesoftware.Steam -vgui
