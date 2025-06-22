# In: modules/home-manager/suites/gaming/scripts/gamescope-steam.sh

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="gamescope-steam"
LOG_PREFIX="[$SCRIPT_NAME]"

log() {
    echo "$LOG_PREFIX $1" >&2
}

# We can still ensure the sink exists, this is harmless.
ensure-game-sink

log "Starting Gamescope Steam session (Flatpak - Simplified)..."

# We are REMOVING all the export commands.
# The Flatpak runtime will set up its own environment.
# Our native Gamescope will still use the correct backend automatically.

exec gamescope \
    --backend=wayland \
    --hdr-debug-force-output \
    --prefer-vk-device \
    --expose-wayland \
    --force-grab-cursor \
    -W 2560 -H 1440 \
    -w 2560 -h 1440 \
    -r 60 \
    -f -b \
    -- flatpak run com.valvesoftware.Steam -bigpicture
