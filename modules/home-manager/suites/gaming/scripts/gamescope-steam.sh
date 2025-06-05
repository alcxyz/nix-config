# modules/home-manager/suites/gaming/scripts/gamescope-steam.sh
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="gamescope-steam"
LOG_PREFIX="[$SCRIPT_NAME]"

log() {
    echo "$LOG_PREFIX $1" >&2
}

# Ensure game sink exists
ensure-game-sink

log "Starting Gamescope Steam session..."

# NVIDIA + Wayland environment setup
export WLR_NO_HARDWARE_CURSORS=1
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export LIBVA_DRIVER_NAME=nvidia
export XDG_SESSION_TYPE=wayland

# Force Wayland everywhere
export SDL_VIDEODRIVER=wayland
export GDK_BACKEND=wayland
export QT_QPA_PLATFORM=wayland
export CLUTTER_BACKEND=wayland
export _JAVA_AWT_WM_NONREPARENTING=1

# Disable X11 completely
export DISPLAY=""

# Configure MangoHUD properly
export MANGOHUD_DLSYM=1

# Ensure we have a Wayland display
if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    log "Error: No Wayland display found. Are you running under Wayland?"
    exit 1
fi

log "Wayland display: ${WAYLAND_DISPLAY}"
log "Gaming session starting"

# Trigger audio management for gaming workspace
manage-game-audio workspace 1 &

# Launch Steam in gamescope
exec mangohud gamescope \
    --backend=wayland \
    --hdr-debug-force-output \
    --prefer-vk-device \
    --steam \
    --expose-wayland \
    --force-grab-cursor \
    -W 2560 -H 1440 \
    -w 2560 -h 1440 \
    -r 60 \
    -f -b \
    -- steam -bigpicture
