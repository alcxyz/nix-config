#!/usr/bin/env bash
# scripts/monitor-workspace-audio.sh
set -euo pipefail

GAMING_WORKSPACE="9"  # Adjust to your gaming workspace
SINK_NAME="GameAudioSink"
LOOPBACK_NAME="GameAudioLoopback"

log() {
    echo "[workspace-audio] $1" >&2
}

get_active_workspace() {
    hyprctl activewindow -j 2>/dev/null | jq -r '.workspace.id // empty' || echo ""
}

create_loopback() {
    # Check if loopback already exists
    if pw-cli list-objects | grep -q "node.name.*$LOOPBACK_NAME"; then
        log "Loopback already exists"
        return 0
    fi
    
    log "Creating audio loopback for local monitoring"
    pw-cli create-node adapter '{
        factory.name="adapter"
        node.name="'$LOOPBACK_NAME'"
        node.description="Game Audio Local Monitor"
        media.class="Audio/Source"
        audio.channels=2
        audio.position="[FL,FR]"
        object.linger=true
        adapter.args={
            "audio.channels": 2,
            "source.props": {
                "node.target": "'$SINK_NAME'.monitor",
                "node.dont-remix": true
            },
            "sink.props": {
                "node.target": "@DEFAULT_SINK@",
                "node.dont-remix": true
            }
        }
    }'
}

remove_loopback() {
    local loopback_id
    loopback_id=$(pw-cli list-objects | grep -B5 "node.name.*$LOOPBACK_NAME" | grep -m1 "id:" | awk '{print $2}' | tr -d ',')
    
    if [[ -n "$loopback_id" ]]; then
        log "Removing audio loopback"
        pw-cli destroy "$loopback_id"
    fi
}

handle_workspace_change() {
    local workspace="$1"
    
    log "Workspace changed to: $workspace"
    
    if [[ "$workspace" == "$GAMING_WORKSPACE" ]]; then
        log "Gaming workspace focused - enabling local audio"
        create_loopback
    else
        log "Non-gaming workspace focused - disabling local audio"
        remove_loopback
    fi
}

# Main execution
if [[ $# -eq 1 ]]; then
    handle_workspace_change "$1"
else
    # Monitor mode - watch for workspace changes
    log "Starting workspace audio monitor..."
    
    # Set initial state
    current_workspace=$(get_active_workspace)
    if [[ -n "$current_workspace" ]]; then
        handle_workspace_change "$current_workspace"
    fi
    
    # Monitor workspace changes
    socat -u UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock - | \
    while read -r line; do
        if [[ "$line" =~ ^workspace\>\>(.+) ]]; then
            workspace="${BASH_REMATCH[1]}"
            handle_workspace_change "$workspace"
        fi
    done
fi
