#!/usr/bin/env bash
set -euo pipefail

# Manage Game Audio Routing
# Handles audio routing based on workspace focus and streaming state

SCRIPT_NAME="manage-game-audio-routing"
LOG_PREFIX="[$SCRIPT_NAME]"

# Configuration (these will be replaced by Nix substitution)
GAMING_WORKSPACE="@gamingWorkspace@"
GAME_APPS="@gameApps@"

log() {
    echo "$LOG_PREFIX $1" >&2
}

is_sunshine_streaming() {
    @procps@/bin/pgrep -f "sunshine.*streaming" > /dev/null 2>&1
}

move_streams_by_pattern() {
    local pattern="$1"
    local target_sink="$2"
    local description="$3"
    
    log "Moving $description streams to $target_sink..."
    
    @pulseaudio@/bin/pactl list sink-inputs | \
        @gnugrep@/bin/grep -B5 -E "$pattern" | \
        @gnugrep@/bin/grep "Sink Input #" | \
        @gawk@/bin/awk '{print $3}' | \
        while read -r stream_id; do
            if [[ -n "$stream_id" ]]; then
                log "Moving $description stream $stream_id to $target_sink"
                @pulseaudio@/bin/pactl move-sink-input "$stream_id" "$target_sink" || {
                    log "Warning: Failed to move stream $stream_id"
                }
            fi
        done
}

main() {
    local workspace="$1"
    
    log "Workspace changed to: $workspace"
    log "Gaming workspace: $GAMING_WORKSPACE"
    
    # Check if Sunshine is currently streaming
    if is_sunshine_streaming; then
        log "Sunshine is streaming, maintaining current audio routing"
        exit 0
    fi
    
    if [[ "$workspace" == "$GAMING_WORKSPACE" ]]; then
        log "Switched to gaming workspace - routing game audio to speakers"
        restore-default-audio
    else
        log "Switched away from gaming workspace - muting game audio"
        # Move game audio to GameAudioSink (effectively muting it)
        move_streams_by_pattern "$GAME_APPS" "GameAudioSink" "game (muting)"
    fi
}

# Validate arguments
if [[ $# -ne 1 ]]; then
    log "Usage: $0 <workspace_number>"
    exit 1
fi

main "$@"
