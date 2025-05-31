#!/usr/bin/env bash
set -euo pipefail

# Gamescope Steam Launcher
# Launches Steam in Big Picture mode via Gamescope with proper input handling

SCRIPT_NAME="gamescope-steam"
LOG_PREFIX="[$SCRIPT_NAME]"

log() {
    echo "$LOG_PREFIX $1" >&2
}

log "Starting Gamescope Steam session..."

# Ensure proper input device access
export WLR_NO_HARDWARE_CURSORS=1
export GAMESCOPE_WAYLAND_DISPLAY=$WAYLAND_DISPLAY

# Log environment info
log "Wayland display: ${WAYLAND_DISPLAY:-none}"
log "Gaming session starting with full input control"

# Enhanced Gamescope flags for input handling
exec gamescope \
    --steam \
    --xwayland-count 2 \
    --expose-wayland \
    --mangoapp \
    --force-grab-cursor \
    -W 1920 -H 1080 \
    -r 60 \
    -f -b \
    -- steam -bigpicture
