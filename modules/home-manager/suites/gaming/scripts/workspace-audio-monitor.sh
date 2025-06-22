# modules/home-manager/suites/gaming/scripts/workspace-audio-monitor.sh
#!/usr/bin/env bash
# Note: GAMING_WORKSPACE, SINK_NAME, etc. are set by the Nix wrapper

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
    # Try multiple methods to get the active workspace
    local workspace
    
    # Method 1: Try activewindow (works when there's a focused window)
    workspace=$(hyprctl activewindow -j 2>/dev/null | jq -r '.workspace.id // empty' 2>/dev/null || true)
    
    # Method 2: If that fails, try activeworkspace (works even on empty workspaces)
    if [[ -z "$workspace" ]]; then
        workspace=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)
    fi
    
    # Method 3: If both fail, try monitors (get workspace of active monitor)
    if [[ -z "$workspace" ]]; then
        workspace=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused == true) | .activeWorkspace.id // empty' 2>/dev/null || true)
    fi
    
    # Fallback
    echo "${workspace:-0}"
}

get_focused_monitor_workspace() {
    # Get the workspace that's currently shown on the focused monitor
    hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused == true) | .activeWorkspace.id // "0"' 2>/dev/null || echo "0"
}

is_gaming_workspace_visible() {
    # Check if gaming workspace is visible on ANY monitor (for multi-monitor setups)
    local visible_workspaces
    visible_workspaces=$(hyprctl monitors -j 2>/dev/null | jq -r '.[].activeWorkspace.id' 2>/dev/null || true)
    
    if [[ -n "$visible_workspaces" ]]; then
        echo "$visible_workspaces" | grep -q "^${GAMING_WORKSPACE}$"
    else
        # Fallback to single monitor check
        local current_workspace
        current_workspace=$(get_active_workspace)
        [[ "$current_workspace" == "$GAMING_WORKSPACE" ]]
    fi
}

is_gaming_workspace_focused() {
    # Check if gaming workspace is on the currently focused monitor
    local focused_workspace
    focused_workspace=$(get_focused_monitor_workspace)
    [[ "$focused_workspace" == "$GAMING_WORKSPACE" ]]
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

handle_focus_change() {
    local event_type="$1"
    
    # Ensure sink always exists
    ensure_sink
    
    # Get current state
    local focused_workspace
    focused_workspace=$(get_focused_monitor_workspace)
    
    log "Focus change ($event_type) - focused monitor shows workspace: $focused_workspace (gaming workspace: $GAMING_WORKSPACE)"
    
    if is_gaming_workspace_focused; then
        log "Gaming workspace is focused - enabling local audio"
        create_loopback
    else
        log "Gaming workspace is not focused - disabling local audio"
        remove_loopback
    fi
}

monitor_workspace_events() {
    log "Starting workspace monitor (gaming workspace: $GAMING_WORKSPACE)"
    
    # Set initial state
    handle_focus_change "initial"
    
    # Check if Hyprland socket exists
    if [[ ! -S "$SOCKET_PATH" ]]; then
        log "Error: Hyprland socket not found at $SOCKET_PATH"
        log "Make sure Hyprland is running and HYPRLAND_INSTANCE_SIGNATURE is set"
        exit 1
    fi
    
    log "Monitoring Hyprland events at $SOCKET_PATH"
    
    # Monitor workspace and focus changes
    while IFS= read -r line; do
        case "$line" in
            workspace\>\>*)
                # Workspace changed
                if [[ "$line" =~ ^workspace\>\>(.+) ]]; then
                    workspace="${BASH_REMATCH[1]}"
                    log "Workspace changed to: $workspace"
                    handle_focus_change "workspace"
                fi
                ;;
            focusedmon\>\>*)
                # Monitor focus changed
                if [[ "$line" =~ ^focusedmon\>\>(.+) ]]; then
                    monitor_info="${BASH_REMATCH[1]}"
                    log "Monitor focus changed: $monitor_info"
                    # Small delay to ensure monitor state is updated
                    sleep 0.1
                    handle_focus_change "monitor"
                fi
                ;;
            activespecial\>\>*)
                # Special workspace (scratchpad) changed
                log "Special workspace event detected"
                handle_focus_change "special"
                ;;
            *)
                # Ignore other events
                ;;
        esac
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
        handle_focus_change "manual"
        ;;
    "init")
        log "Initializing audio system"
        ensure_sink
        handle_focus_change "init"
        ;;
    "debug")
        # Debug mode to test workspace detection methods
        log "Debug mode - testing workspace detection methods"
        log "Gaming workspace: $GAMING_WORKSPACE"
        log "Method 1 (activewindow): $(hyprctl activewindow -j 2>/dev/null | jq -r '.workspace.id // "failed"' 2>/dev/null || echo "failed")"
        log "Method 2 (activeworkspace): $(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id // "failed"' 2>/dev/null || echo "failed")"
        log "Method 3 (focused monitor): $(get_focused_monitor_workspace)"
        log "All monitor workspaces: $(hyprctl monitors -j 2>/dev/null | jq -r '.[].activeWorkspace.id' 2>/dev/null | tr '\n' ' ')"
        log "Gaming workspace visible: $(is_gaming_workspace_visible && echo "yes" || echo "no")"
        log "Gaming workspace focused: $(is_gaming_workspace_focused && echo "yes" || echo "no")"
        ;;
    *)
        log "Usage: $0 [monitor|check|init|debug]"
        exit 1
        ;;
esac
