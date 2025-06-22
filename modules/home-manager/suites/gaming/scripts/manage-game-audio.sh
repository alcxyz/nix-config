#!/usr/bin/env bash
# Note: GAMING_WORKSPACE is set by the Nix wrapper, not in this file

log() {
    echo "[game-audio] $1" >&2
}

ensure_sink() {
    if ! pactl list short sinks | grep -q "$SINK_NAME"; then
        log "Creating $SINK_NAME"
        pactl load-module module-null-sink \
            sink_name="$SINK_NAME" \
            sink_properties="device.description='Virtual Sink for Games and Streaming'" \
            rate=48000 \
            channels=2 >/dev/null
    fi
}

get_active_workspace() {
    hyprctl activewindow -j 2>/dev/null | jq -r '.workspace.id // "0"' || echo "0"
}

is_gaming_workspace_active() {
    local active_ws=$(get_active_workspace)
    
    # Debug output
    log "Active workspace: '$active_ws', Gaming workspace: '$GAMING_WORKSPACE'"
    
    [[ "$active_ws" == "$GAMING_WORKSPACE" ]]
}

create_loopback() {
    if pactl list short modules | grep -q "GameAudioLoopback"; then
        log "Loopback already exists"
        return 0
    fi
    
    log "Creating audio loopback for local monitoring"
    pactl load-module module-loopback \
        source="$SINK_NAME.monitor" \
        sink="@DEFAULT_SINK@" \
        source_dont_move=true \
        sink_dont_move=true \
        source_output_properties="media.name=GameAudioLoopback" >/dev/null
}

remove_loopback() {
    local module_id
    module_id=$(pactl list short modules | grep "GameAudioLoopback" | cut -f1 || true)
    
    if [[ -n "$module_id" ]]; then
        log "Removing audio loopback (module $module_id)"
        pactl unload-module "$module_id"
    else
        log "No loopback to remove"
    fi
}

handle_current_workspace() {
    ensure_sink
    
    if is_gaming_workspace_active; then
        log "Gaming workspace is active - enabling local audio"
        create_loopback
    else
        log "Gaming workspace is not active - disabling local audio"
        remove_loopback
    fi
}

# Main execution
case "${1:-}" in
    "init")
        log "Initializing game audio system (gaming workspace: $GAMING_WORKSPACE)"
        ensure_sink
        ;;
    "workspace")
        log "Checking workspace change"
        handle_current_workspace
        ;;
    "check")
        handle_current_workspace
        ;;
    *)
        log "Usage: manage-game-audio [init|workspace|check]"
        exit 1
        ;;
esac
