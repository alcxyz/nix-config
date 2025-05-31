#!/usr/bin/env bash
set -euo pipefail

# Prepare Streaming Audio
# Routes game audio to GameAudioSink for streaming capture

SCRIPT_NAME="prepare-streaming-audio"
LOG_PREFIX="[$SCRIPT_NAME]"

# Configuration (these will be replaced by Nix substitution)
GAME_APPS="@gameApps@"
HOST_BYPASS_APPS="@hostBypassApps@"

log() {
    echo "$LOG_PREFIX $1" >&2
}

get_default_sink() {
    @pulseaudio@/bin/pactl get-default-sink
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
    log "Preparing audio for streaming..."
    
    # Verify GameAudioSink exists
    if ! @pulseaudio@/bin/pactl list sinks | @gnugrep@/bin/grep -q "GameAudioSink"; then
        log "Error: GameAudioSink not found. Is the gaming module enabled?"
        exit 1
    fi
    
    # Set GameAudioSink as default for new applications
    log "Setting GameAudioSink as default sink"
    @pulseaudio@/bin/pactl set-default-sink GameAudioSink
    
    # Move existing game audio streams to GameAudioSink
    move_streams_by_pattern "$GAME_APPS" "GameAudioSink" "game"
    
    # Keep host applications on physical speakers (get default sink dynamically)
    if [[ -n "$HOST_BYPASS_APPS" ]]; then
        local default_sink
        default_sink=$(get_default_sink)
        move_streams_by_pattern "$HOST_BYPASS_APPS" "$default_sink" "host bypass"
    fi
    
    log "Audio preparation complete - game audio routed to streaming sink"
}

main "$@"
