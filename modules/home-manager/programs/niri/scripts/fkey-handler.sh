#!/usr/bin/env bash

# F-key double-tap handler for niri.
# Single tap: switch to workspace N.
# Double tap: toggle scratch workspace.

KEY_NAME="$1"
WORKSPACE_NUM="$2"
TIMEOUT_MS=300

STATE_FILE="/tmp/niri_fkey_tap.state"
CURRENT_TIME_NS=$(date +%s%N)

PERFORM_DEFAULT_ACTION=true

if [ -f "$STATE_FILE" ]; then
    if IFS=' ' read -r LAST_KEY_NAME LAST_TIME_NS < "$STATE_FILE"; then
        TIME_DIFF_NS=$((CURRENT_TIME_NS - LAST_TIME_NS))
        TIMEOUT_NS=$((TIMEOUT_MS * 1000000))

        if [ "$LAST_KEY_NAME" == "$KEY_NAME" ] && [ "$TIME_DIFF_NS" -lt "$TIMEOUT_NS" ]; then
            # Double tap detected — toggle scratch workspace
            ~/.config/niri/scripts/scratch-toggle.sh
            rm -f "$STATE_FILE"
            PERFORM_DEFAULT_ACTION=false
        fi
    fi
fi

if [ "$PERFORM_DEFAULT_ACTION" = true ]; then
    echo "$KEY_NAME $CURRENT_TIME_NS" > "$STATE_FILE"
    niri msg action focus-workspace "$WORKSPACE_NUM"
fi
