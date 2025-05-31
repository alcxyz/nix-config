#!/usr/bin/env bash
set -euo pipefail

# Restore Default Audio
# Routes game audio back to physical speakers for local play

SCRIPT_NAME="restore-default-audio"
LOG_PREFIX="[$SCRIPT_NAME]"

# Configuration (these will be replaced by Nix substitution)
GAME_APPS="@gameApps@"

log() {
    echo "$LOG_PREFIX $1" >&2
}

get_physical_sink() {
    # Find the actual hardware sink (not GameAudioSink)
    local current_default
    current_default=$(@pulseaudio@/bin/pactl get-default-sink)
    
    if [[ "$current_default" != "GameAudioSink" ]]; then
        echo "$current_default"
        return 0
    fi
    
    # Find first non-GameAudioSink
    @pulseaudio@/bin/pactl list short sinks | \
        @gnugrep@/bin/grep -v GameAudioSink | \
        @gawk@/bin/awk '{print $2}' | \
        head -1
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
    log "Restoring default audio configuration..."
    
    # Get the physical audio sink
    local physical_sink
    physical_sink=$(get_physical_sink)
    
    if [[ -z "$physical_sink" ]]; then
        log "Error: Could not find physical audio sink"
        exit 1
    fi
    
    log "Using physical sink: $physical_sink"
    
    # Restore original default sink
    log "Setting $physical_sink as default sink"
    @pulseaudio@/bin/pactl set-default-sink "$physical_sink"
    
    # Move game audio back to physical speakers for local play
    move_streams_by_pattern "$GAME_APPS" "$physical_sink" "game"
    
    log "Audio restoration complete - game audio routed to physical speakers"
}

main "$@"
