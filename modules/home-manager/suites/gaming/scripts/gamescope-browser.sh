#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="gamescope-browser"
LOG_PREFIX="[$SCRIPT_NAME]"

log() {
    echo "$LOG_PREFIX $1" >&2
}

log "Starting Gamescope Browser session..."

# Basic NVIDIA setup
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia

log "Browser session starting in gamescope"

# Launch Chromium optimized for gaming/streaming
exec gamescope \
    --prefer-vk-device \
    -W 1920 -H 1080 \
    -w 1920 -h 1080 \
    -r 60 \
    -f -b \
    -- chromium \
        --new-window \
        --start-fullscreen \
        --disable-features=UseOzonePlatform \
        --disable-gpu-sandbox \
        --no-sandbox \
        --disable-dev-shm-usage \
        --disable-web-security \
        --disable-background-timer-throttling \
        --disable-backgrounding-occluded-windows \
        --disable-renderer-backgrounding \
        --enable-features=VaapiVideoDecoder \
        --use-gl=desktop \
        --enable-gpu-rasterization \
        --enable-zero-copy
