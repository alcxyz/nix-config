#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="manage-game-audio-routing"
LOG_PREFIX="[$SCRIPT_NAME]"

# Nix-substituted variables
GAMING_WORKSPACE_NAME="@gamingWorkspaceName@" # e.g., "9"
LOOPBACK_NODE_NICK="GameAudioLoopbackForLocalPlayback"

log() {
    echo "$LOG_PREFIX $1" >&2 # Log to stderr. Consider file logging for Hyprland exec: echo ... >> /tmp/manage_audio.log
}

get_current_physical_sink_name() {
    local current_default_sink
    current_default_sink=$(@pulseaudio@/bin/pactl get-default-sink 2>/dev/null)
    if [[ -n "$current_default_sink" && "$current_default_sink" != "GameAudioSink" ]]; then
        echo "$current_default_sink"
        return 0
    fi
    @pulseaudio@/bin/pactl list short sinks 2>/dev/null | \
        @gnugrep@/bin/grep -v "GameAudioSink" | \
        @gawk@/bin/awk '{print $2}' | \
        head -n 1
}

create_loopback() {
    local physical_sink_target="$1"
    if [[ -z "$physical_sink_target" ]]; then
        log "Error: No physical sink target provided for loopback creation."
        return 1
    fi

    if @pulseaudio@/bin/pactl list modules short | @gnugrep@/bin/grep -q "argument=\"node.nick=$LOOPBACK_NODE_NICK\""; then
        log "Loopback '$LOOPBACK_NODE_NICK' already exists."
        return 0
    fi

    log "Creating loopback from GameAudioSink.monitor to $physical_sink_target"
    if @pulseaudio@/bin/pactl load-module module-loopback \
        source="GameAudioSink.monitor" \
        sink="$physical_sink_target" \
        latency_msec=20 \
        source_dont_move=true \
        sink_dont_move=true \
        properties="node.nick=$LOOPBACK_NODE_NICK"; then # module_name=... module_author=... etc.
        log "Loopback '$LOOPBACK_NODE_NICK' created."
    else
        log "Error: Failed to create loopback '$LOOPBACK_NODE_NICK'."
        # Check if GameAudioSink.monitor exists: pactl list sources short | grep GameAudioSink.monitor
        return 1
    fi
}

destroy_loopback() {
    log "Attempting to destroy loopback '$LOOPBACK_NODE_NICK'..."
    local module_id
    module_id=$(@pulseaudio@/bin/pactl list modules short | @gnugrep@/bin/grep "module-loopback" | @gnugrep@/bin/grep "argument=\"node.nick=$LOOPBACK_NODE_NICK\"" | @gawk@/bin/awk '{print $1}')

    if [[ -n "$module_id" ]]; then
        log "Destroying loopback module ID: $module_id"
        if @pulseaudio@/bin/pactl unload-module "$module_id"; then
            log "Loopback '$LOOPBACK_NODE_NICK' (module $module_id) destroyed."
        else
            log "Error: Failed to unload module $module_id for loopback '$LOOPBACK_NODE_NICK'."
        fi
    else
        log "Loopback '$LOOPBACK_NODE_NICK' not found or already destroyed."
    fi
}

get_current_hyprland_active_workspace_id() {
    local hyprctl_output
    hyprctl_output=$(@hyprland@/bin/hyprctl activeworkspace -j 2>/dev/null) || {
        log "Error: hyprctl activeworkspace command failed."
        return 1
    }
    
    local active_workspace_id
    active_workspace_id=$(echo "$hyprctl_output" | @jq@/bin/jq -r '.id | tostring') || {
        log "Error: jq failed to parse hyprctl output or extract .id."
        return 1
    }

    if [[ "$active_workspace_id" == "null" || -z "$active_workspace_id" ]]; then
        log "Error: Could not determine active Hyprland workspace ID from hyprctl output."
        return 1
    fi
    echo "$active_workspace_id"
}

main() {
    # Give Hyprland a moment to fully switch workspace and update its state
    sleep 0.1

    if ! @pulseaudio@/bin/pactl info > /dev/null 2>&1; then
        log "Error: PulseAudio server not available. Exiting."
        exit 1
    fi
    if ! @pipewire@/bin/pw-cli info > /dev/null 2>&1; then
        log "Error: PipeWire server not available. Exiting." # Though pactl check is primary for this script
        exit 1
    fi


    local current_active_id
    current_active_id=$(get_current_hyprland_active_workspace_id)

    if [[ -z "$current_active_id" ]]; then
        log "Exiting due to inability to determine active workspace."
        exit 1
    fi

    log "Current active workspace ID: '$current_active_id'. Configured gaming workspace name/ID: '$GAMING_WORKSPACE_NAME'."

    if [[ "$current_active_id" == "$GAMING_WORKSPACE_NAME" ]]; then
        log "Switched TO gaming workspace '$GAMING_WORKSPACE_NAME'."
        local physical_sink
        physical_sink=$(get_current_physical_sink_name)
        if [[ -n "$physical_sink" ]]; then
            log "Target physical sink for loopback: $physical_sink"
            create_loopback "$physical_sink"
        else
            log "Error: Could not determine physical sink. Cannot create loopback."
        fi
    else
        log "Switched AWAY from gaming workspace '$GAMING_WORKSPACE_NAME' (current is '$current_active_id')."
        destroy_loopback
    fi
}

main
