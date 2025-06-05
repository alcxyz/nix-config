# modules/home-manager/suites/gaming/scripts/gamescope-steam.sh
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="gamescope-steam"
LOG_PREFIX="[$SCRIPT_NAME]"

log() {
    echo "$LOG_PREFIX $1" >&2
}

# No longer need ensure-game-sink here, as the monitor handles it.
log "Starting Gamescope Steam (Flatpak) session..."

# Environment variables are still useful for gamescope and the driver
export WLR_NO_HARDWARE_CURSORS=1
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export LIBVA_DRIVER_NAME=nvidia
export XDG_SESSION_TYPE=wayland
export MANGOHUD_DLSYM=1

log "Gaming session starting"

# The command to launch Flatpak Steam
FLATPAK_STEAM_CMD="flatpak run com.valvesoftware.Steam -bigpicture"

# Use mangohud to launch gamescope, which in turn launches the flatpak command
exec mangohud gamescope \
    --backend=wayland \
    --hdr-debug-force-output \
    --prefer-vk-device \
    --expose-wayland \
    --force-grab-cursor \
    -W 2560 -H 1440 \
    -w 2560 -h 1440 \
    -r 60 \
    -f -b \
    -- $FLATPAK_STEAM_CMD
