# modules/home-manager/suites/gaming/scripts/workspace-audio-monitor.sh
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="workspace-audio-monitor"
SINK_NAME="GameAudioSink"
GAMING_WORKSPACE="@GAMING_WORKSPACE@"  # Will be replaced by Nix
SOCKET_PATH="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

log() {
    echo "[$SCRIPT_NAME] $1" >&2
}

ensure_sink() {
    if ! pactl list short sinks | grep -q "$SINK_NAME"; then
        log "Creating $SINK_NAME"
        if pactl load-module module-null-sink \
            sink_name="$SINK_NAME" \
            sink_properties="device.description='Virtual Sink for Games and Streaming'" \
            rate=48000 \
            channels=2 >/dev/null; then
            log "GameAudioSink created successfully"
        else
            log "Failed to create GameAudioSink"
            return 1
        fi
    fi
}

get_active_workspace() {
    hyprctl activewindow -j 2>/dev/null | jq -r '.workspace.id // "0"' || echo "0"
}

create_loopback() {
    if pactl list short modules | grep -q "GameAudioLoopback"; then
        return 0
    fi
    
    log "Creating audio loopback for local monitoring"
    if pactl load-module module-loopback \
        source="$SINK_NAME.monitor" \
        sink="@DEFAULT_SINK@" \
        source_dont_move=true \
        sink_dont_move=true \
        source_output_properties="media.name=GameAudioLoopback" >/dev/null; then
        log "Audio loopback created"
    else
        log "Failed to create audio loopback"
        return 1
    fi
}

remove_loopback() {
    local module_id
    module_id=$(pactl list short modules | grep "GameAudioLoopback" | cut -f1 || true)
    
    if [[ -n "$module_id" ]]; then
        log "Removing audio loopback (module $module_id)"
        if pactl unload-module "$module_id"; then
            log "Audio loopback removed"
        else
            log "Failed to remove audio loopback"
        fi
    fi
}

handle_workspace_change() {
    local workspace="$1"
    
    log "Workspace changed to: $workspace"
    
    # Ensure sink always exists
    ensure_sink
    
    if [[ "$workspace" == "$GAMING_WORKSPACE" ]]; then
        log "Gaming workspace active - enabling local audio"
        create_loopback
    else
        log "Non-gaming workspace active - disabling local audio"
        remove_loopback
    fi
}

monitor_workspace_events() {
    log "Starting workspace monitor (gaming workspace: $GAMING_WORKSPACE)"
    
    # Set initial state
    local current_workspace
    current_workspace=$(get_active_workspace)
    if [[ -n "$current_workspace" ]]; then
        handle_workspace_change "$current_workspace"
    fi
    
    # Check if Hyprland socket exists
    if [[ ! -S "$SOCKET_PATH" ]]; then
        log "Error: Hyprland socket not found at $SOCKET_PATH"
        log "Make sure Hyprland is running and HYPRLAND_INSTANCE_SIGNATURE is set"
        exit 1
    fi
    
    log "Monitoring Hyprland events at $SOCKET_PATH"
    
    # Monitor workspace changes
    while IFS= read -r line; do
        if [[ "$line" =~ ^workspace\>\>(.+) ]]; then
            workspace="${BASH_REMATCH[1]}"
            handle_workspace_change "$workspace"
        elif [[ "$line" =~ ^focusedmon\>\>(.+) ]]; then
            # Handle monitor focus changes (might switch workspace)
            sleep 0.1  # Small delay to let workspace change complete
            current_workspace=$(get_active_workspace)
            handle_workspace_change "$current_workspace"
        fi
    done < <(socat -u UNIX-CONNECT:"$SOCKET_PATH" -)
}

cleanup() {
    log "Shutting down workspace monitor"
    remove_loopback
    exit 0
}

# Handle cleanup on exit
trap cleanup SIGTERM SIGINT

# Main execution
case "${1:-monitor}" in
    "monitor")
        monitor_workspace_events
        ;;
    "check")
        current_workspace=$(get_active_workspace)
        handle_workspace_change "$current_workspace"
        ;;
    "init")
        log "Initializing audio system"
        ensure_sink
        current_workspace=$(get_active_workspace)
        handle_workspace_change "$current_workspace"
        ;;
    *)
        log "Usage: $0 [monitor|check|init]"
        exit 1
        ;;
esac
