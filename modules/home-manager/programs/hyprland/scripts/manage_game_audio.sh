#!/usr/bin/env bash
# users/alc/manage_game_audio.sh

# Define the log file path
AUDIO_LOG_FILE="/tmp/manage_game_audio.log"

# Clear previous log file or ensure it exists and is writable
touch "$AUDIO_LOG_FILE"
chmod 666 "$AUDIO_LOG_FILE"

# Function to log messages with a timestamp
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$AUDIO_LOG_FILE"
}

log_message "--- Audio Management Script Called ---"

# Configuration
# Ensure this matches how you refer to the workspace in Hyprland rules/binds
# If hyprctl activeworkspace -j returns an ID like "9", use "9".
# If it returns a name like "name:9", use "name:9".
# Let's assume for now it's just the number.
GAMING_WORKSPACE_ID="9"
TARGET_APP_NAME_PATTERN="Steam" # Or a more specific process name if Steam is too broad

# Get current active workspace ID
ACTIVE_WORKSPACE_ID=$(hyprctl activeworkspace -j | jq -r '.id')
if [[ -z "$ACTIVE_WORKSPACE_ID" ]]; then
    log_message "Error: Could not determine active workspace ID."
    exit 1
fi
log_message "Active Workspace ID: '$ACTIVE_WORKSPACE_ID', Target Gaming Workspace ID: '$GAMING_WORKSPACE_ID'"

# Find the audio sink input index for the target application
# This uses pactl and awk to find the index.
# It looks for application.process.binary or application.name containing the pattern.
SINK_INPUT_INDEX=$(pactl list sink-inputs | awk -v app="$TARGET_APP_NAME_PATTERN" '
    BEGIN { RS="Sink Input #"; FS="\n"; ORS="" }
    # Check application.process.binary first
    $0 ~ "application.process.binary = \"" app "\"" {print $1; found=1; exit}
    $0 ~ "application.process.binary = \"" tolower(app) "\"" {print $1; found=1; exit}
    # Then check application.name if not found by binary
    $0 ~ "application.name = \"" app "\"" {print $1; found=1; exit}
    $0 ~ "application.name = \"" tolower(app) "\"" {print $1; found=1; exit}
    END {if (!found) print ""}
' | tr -d '[:space:]')


if [[ -n "$SINK_INPUT_INDEX" ]]; then
    log_message "Found Sink Input Index for '$TARGET_APP_NAME_PATTERN': $SINK_INPUT_INDEX"

    # Check if the sink input is currently muted
    CURRENT_MUTE_STATUS=$(pactl list sink-inputs | awk -v idx="$SINK_INPUT_INDEX" '
        BEGIN {RS="Sink Input #"; FS="\n"}
        $1 == idx {
            for (i=1; i<=NF; ++i) {
                if ($i ~ /Mute: (yes|no)/) {
                    gsub(/.*Mute: /, "", $i);
                    print $i;
                    exit;
                }
            }
        }
    ')
    log_message "Current Mute Status for index $SINK_INPUT_INDEX: '$CURRENT_MUTE_STATUS'"

    if [[ "$ACTIVE_WORKSPACE_ID" == "$GAMING_WORKSPACE_ID" ]]; then
        log_message "Action: Switched TO gaming workspace. Setting mute to NO for index $SINK_INPUT_INDEX."
        pactl set-sink-input-mute "$SINK_INPUT_INDEX" 0 # 0 for no (unmute)
        if [[ $? -ne 0 ]]; then
            log_message "Error: pactl unmute command failed."
        else
            log_message "Successfully unmuted."
        fi
    else
        log_message "Action: Switched AWAY from gaming workspace. Setting mute to YES for index $SINK_INPUT_INDEX."
        pactl set-sink-input-mute "$SINK_INPUT_INDEX" 1 # 1 for yes (mute)
        if [[ $? -ne 0 ]]; then
            log_message "Error: pactl mute command failed."
        else
            log_message "Successfully muted."
        fi
    fi
else
    log_message "Warning: Sink Input for '$TARGET_APP_NAME_PATTERN' not found. No action taken."
fi

log_message "--- Audio Management Script Finished ---"
exit 0
