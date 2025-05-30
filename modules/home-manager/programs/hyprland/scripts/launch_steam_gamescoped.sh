#!/usr/bin/env bash

# Script to launch Steam in Gamescope

# Desired Gamescope parameters
GAMESCOPE_WIDTH=1920
GAMESCOPE_HEIGHT=1080
GAMESCOPE_REFRESH=60
GAMESCOPE_EXTRA_FLAGS="--steam -f -b" # Add other flags like -U, --fsr-sharpness, --expose-wayland as needed

# Steam command
STEAM_COMMAND="steam -bigpicture" # Or just "steam"

# Full command
# Ensure gamescope and steam are in PATH
gamescope \
    -W "$GAMESCOPE_WIDTH" \
    -H "$GAMESCOPE_HEIGHT" \
    -r "$GAMESCOPE_REFRESH" \
    $GAMESCOPE_EXTRA_FLAGS \
    -- \
    $STEAM_COMMAND

# Optional: Add logging or error handling here
exec &> /tmp/launch_steam_gamescoped.log # Redirect all output to a log for debugging the script itself
