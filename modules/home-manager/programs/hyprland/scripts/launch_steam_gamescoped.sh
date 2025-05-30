#!/usr/bin/env bash

# Script to launch Steam in Gamescope with better logging

# Define the log file path (consider XDG_CACHE_HOME if you prefer)
LOG_FILE="/tmp/launch_steam_gamescoped.log"

# Clear previous log file or ensure it exists and is writable
# > "$LOG_FILE" # This clears the file
touch "$LOG_FILE"
chmod 666 "$LOG_FILE" # For easy access during debugging

# Function to log messages with a timestamp
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

log_message "Script started."

# SDL Verbose Logging (good for video/surface issues)
export SDL_LOG_CATEGORY_VIDEO=5
log_message "SDL_LOG_CATEGORY_VIDEO set to 5."

# Gamescope parameters
GAMESCOPE_WIDTH=1920
GAMESCOPE_HEIGHT=1080
GAMESCOPE_REFRESH=60

# --- CHOOSE ONE BACKEND FLAG FOR TESTING ---
# GAMESCOPE_BACKEND_FLAG="--backend wayland"
GAMESCOPE_BACKEND_FLAG="--backend sdl" # Or try with this one
# GAMESCOPE_BACKEND_FLAG="" # To test auto-detection (default)

GAMESCOPE_EXTRA_FLAGS="--steam -f -b --expose-wayland" # --steam is often important

STEAM_COMMAND="steam -bigpicture"

log_message "Gamescope settings:"
log_message "  Backend: ${GAMESCOPE_BACKEND_FLAG:-auto}" # Show 'auto' if flag is empty
log_message "  Resolution: ${GAMESCOPE_WIDTH}x${GAMESCOPE_HEIGHT}@${GAMESCOPE_REFRESH}Hz"
log_message "  Extra Flags: ${GAMESCOPE_EXTRA_FLAGS}"
log_message "  Steam Command: ${STEAM_COMMAND}"
log_message "--- Starting Gamescope ---"

# Execute gamescope and redirect all its stdout and stderr to the log file
# The '{ ... ; } > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)' construct is robust.
# It tees both stdout and stderr to the file AND shows them on the terminal.
# Simpler for just file: '{ ... ; } >> "$LOG_FILE" 2>&1'

{ # Start of command group
    gamescope \
        ${GAMESCOPE_BACKEND_FLAG} \
        -W "$GAMESCOPE_WIDTH" \
        -H "$GAMESCOPE_HEIGHT" \
        -r "$GAMESCOPE_REFRESH" \
        ${GAMESCOPE_EXTRA_FLAGS} \
        -- \
        $STEAM_COMMAND
    GAMESCOPE_EXIT_CODE=$? # Capture exit code
    log_message "Gamescope exited with code: $GAMESCOPE_EXIT_CODE"
} >> "$LOG_FILE" 2>&1 # Redirect stdout and stderr of the group to the log file

# If you also want to see the output in the terminal simultaneously (useful for interactive debugging):
# } > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

log_message "Script finished."
exit $GAMESCOPE_EXIT_CODE
