#!/usr/bin/env bash

set -euo pipefail

DOUBLE_TAP_MS=300
GUARD_SERVICE="hyprland-bar-pointer-guard.service"
RUNTIME_DIR="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}"
TAP_STATE_FILE="$RUNTIME_DIR/hypr-fkey-tap.state"
HELD_MARKER="$RUNTIME_DIR/hyprland-bar-pointer-guard.held"

usage() {
    echo "Usage: fkey_handler.sh [press|release] KEY WORKSPACE" >&2
    echo "       fkey_handler.sh KEY WORKSPACE" >&2
    exit 2
}

handle_tap() {
    local key_name="$1"
    local workspace_num="$2"
    local current_time_ns last_key_name last_time_ns time_diff_ns timeout_ns

    current_time_ns="$(date +%s%N)"
    timeout_ns=$((DOUBLE_TAP_MS * 1000000))

    if [[ -f "$TAP_STATE_FILE" ]] \
        && IFS=' ' read -r last_key_name last_time_ns < "$TAP_STATE_FILE" \
        && [[ "$last_key_name" == "$key_name" ]] \
        && [[ "$last_time_ns" =~ ^[0-9]+$ ]]; then
        time_diff_ns=$((current_time_ns - last_time_ns))
        if ((time_diff_ns < timeout_ns)); then
            rm -f "$TAP_STATE_FILE"
            hyprctl dispatch togglespecialworkspace
            return
        fi
    fi

    printf '%s %s\n' "$key_name" "$current_time_ns" > "$TAP_STATE_FILE"
    hyprctl dispatch workspace "$workspace_num"
}

# Preserve the original two-argument behavior for profiles that have not
# adopted press/release gesture bindings.
if (($# == 2)); then
    handle_tap "$1" "$2"
    exit
fi

(($# == 3)) || usage
action="$1"
key_name="$2"
workspace_num="$3"

[[ "$key_name" =~ ^F[1-6]$ ]] || usage
[[ "$workspace_num" =~ ^[1-6]$ ]] || usage

case "$action" in
    press)
        handle_tap "$key_name" "$workspace_num"
        systemctl --user start --no-block "$GUARD_SERVICE"
        ;;
    release)
        if [[ -e "$HELD_MARKER" ]]; then
            rm -f "$TAP_STATE_FILE"
        fi

        systemctl --user stop --no-block "$GUARD_SERVICE"
        ;;
    *) usage ;;
esac
