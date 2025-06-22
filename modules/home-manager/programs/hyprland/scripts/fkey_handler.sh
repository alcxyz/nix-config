#!/usr/bin/env bash

# Script to handle F-key taps for single and double tap actions on NixOS

# Ensure coreutils (for date) and hyprland (for hyprctl) are in PATH.
# This is typically handled by your NixOS configuration.

KEY_NAME="$1"      # e.g., "F1", "F2"
WORKSPACE_NUM="$2" # e.g., "1", "2"
TIMEOUT_MS=300     # Milliseconds to consider a double tap

# Using a state file in /tmp, which is standard
STATE_FILE="/tmp/hypr_fkey_tap.state"
CURRENT_TIME_NS=$(date +%s%N)

# Default action: switch workspace
ACTION_CMD="hyprctl dispatch workspace $WORKSPACE_NUM"
PERFORM_DEFAULT_ACTION=true

if [ -f "$STATE_FILE" ]; then
    # Read last key and time. Use `read -r` to prevent backslash interpretation.
    if IFS=' ' read -r LAST_KEY_NAME LAST_TIME_NS < "$STATE_FILE"; then
        TIME_DIFF_NS=$((CURRENT_TIME_NS - LAST_TIME_NS))
        TIMEOUT_NS=$((TIMEOUT_MS * 1000000)) # Convert TIMEOUT_MS to nanoseconds

        if [ "$LAST_KEY_NAME" == "$KEY_NAME" ] && [ "$TIME_DIFF_NS" -lt "$TIMEOUT_NS" ]; then
            # Double tap detected
            ACTION_CMD="hyprctl dispatch togglespecialworkspace"
            # Clear state file to prevent triple tap from re-triggering special
            # and to ensure next single tap works as expected.
            rm -f "$STATE_FILE"
            PERFORM_DEFAULT_ACTION=false # We are doing the special action instead
        fi
    else
        # If reading fails, reset state by ensuring default action and writing new state
        PERFORM_DEFAULT_ACTION=true
        # Optionally, log an error here if you want to debug state file issues
        # echo "Error reading state file: $STATE_FILE" >&2
    fi
fi

# If not a double tap, or if it's a different key, or first tap, or read error
if [ "$PERFORM_DEFAULT_ACTION" = true ]; then
    echo "$KEY_NAME $CURRENT_TIME_NS" > "$STATE_FILE"
fi

# Execute the determined command
# Using `eval` here is generally okay as ACTION_CMD is constructed from controlled inputs.
eval "$ACTION_CMD"
