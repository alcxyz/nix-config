#!/usr/bin/env bash

set -euo pipefail

DOUBLE_TAP_MS=300
RUNTIME_DIR="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}"
TAP_STATE_FILE="$RUNTIME_DIR/hypr-fkey-tap.state"

usage() {
    echo "Usage: fkey_handler.sh KEY WORKSPACE" >&2
    exit 2
}

(($# == 2)) || usage
key_name="$1"
workspace_num="$2"

[[ "$key_name" =~ ^F[1-6]$ ]] || usage
[[ "$workspace_num" =~ ^[1-6]$ ]] || usage

current_time_ns="$(date +%s%N)"
timeout_ns=$((DOUBLE_TAP_MS * 1000000))
config_provider="$(hyprctl status -j 2>/dev/null | sed -n 's/.*"configProvider": *"\([^"]*\)".*/\1/p')"

toggle_special_workspace() {
    if [[ "$config_provider" == lua ]]; then
        hyprctl eval 'hl.dispatch(hl.dsp.workspace.toggle_special(""))'
    else
        hyprctl dispatch togglespecialworkspace
    fi
}

focus_workspace() {
    if [[ "$config_provider" == lua ]]; then
        hyprctl eval "hl.dispatch(hl.dsp.focus({ workspace = \"$workspace_num\" }))"
    else
        hyprctl dispatch workspace "$workspace_num"
    fi
}

if [[ -f "$TAP_STATE_FILE" ]] \
    && IFS=' ' read -r last_key_name last_time_ns < "$TAP_STATE_FILE" \
    && [[ "$last_key_name" == "$key_name" ]] \
    && [[ "$last_time_ns" =~ ^[0-9]+$ ]]; then
    time_diff_ns=$((current_time_ns - last_time_ns))
    if ((time_diff_ns < timeout_ns)); then
        rm -f "$TAP_STATE_FILE"
        toggle_special_workspace
        exit
    fi
fi

umask 077
printf '%s %s\n' "$key_name" "$current_time_ns" > "$TAP_STATE_FILE"
focus_workspace
