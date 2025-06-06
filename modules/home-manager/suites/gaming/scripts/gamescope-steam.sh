# In: modules/home-manager/suites/gaming/scripts/gamescope-steam.sh

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="gamescope-steam"
LOG_PREFIX="[$SCRIPT_NAME]"

log() {
    echo "$LOG_PREFIX $1" >&2
}

# This is still useful to ensure the sink exists before launch
ensure-game-sink

log "Starting Gamescope Steam session (Flatpak)..."

# All these environment variables are for the NATIVE Gamescope wrapper,
# so they are still correct and necessary.
export WLR_NO_HARDWARE_CURSORS=1
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export LIBVA_DRIVER_NAME=nvidia
export XDG_SESSION_TYPE=wayland
export SDL_VIDEODRIVER=wayland
export GDK_BACKEND=wayland
export QT_QPA_PLATFORM=wayland
export CLUTTER_BACKEND=wayland
export _JAVA_AWT_WM_NONREPARENTING=1
export DISPLAY=""
export MANGOHUD_DLSYM=1

if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    log "Error: No Wayland display found. Are you running under Wayland?"
    exit 1
fi

log "Wayland display: ${WAYLAND_DISPLAY}"
log "Launching Flatpak Steam in Gamescope"

# THE ONLY CHANGE IS HERE:
# We replace `steam -bigpicture` with `flatpak run ...`
exec mangohud gamescope \
    --backend=wayland \
    --hdr-debug-force-output \
    --prefer-vk-device \
    --expose-wayland \
    --grab-keyboard \
    -W 2560 -H 1440 \
    -w 2560 -h 1440 \
    -r 60 \
    -f -b \
    -- flatpak run com.valvesoftware.Steam -bigpicture
