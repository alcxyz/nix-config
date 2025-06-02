#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="prepare-streaming-audio"
LOG_PREFIX="[$SCRIPT_NAME]"

# Configuration (these will be replaced by Nix substitution)
GAME_APPS="@gameApps@"
HOST_BYPASS_APPS="@hostBypassApps@"

log() {
    echo "$LOG_PREFIX $1" >&2 # Consider logging to a file for easier debugging: echo "$LOG_PREFIX $1" >> /tmp/prepare_audio.log
}

get_physical_sink_name() {
    # Get the current default sink, ensure it's not GameAudioSink
    local current_default_sink
    current_default_sink=$(@pulseaudio@/bin/pactl get-default-sink 2>/dev/null)

    if [[ -n "$current_default_sink" && "$current_default_sink" != "GameAudioSink" ]]; then
        echo "$current_default_sink"
        return 0
    fi

    # Fallback: find first non-GameAudioSink listed
    @pulseaudio@/bin/pactl list short sinks 2>/dev/null | \
        @gnugrep@/bin/grep -v "GameAudioSink" | \
        @gawk@/bin/awk '{print $2}' | \
        head -n 1
}

move_streams_by_pattern() {
    local pattern="$1"
    local target_sink="$2"
    local description="$3"

    log "Attempting to move $description streams matching '$pattern' to sink '$target_sink'..."

    # Get a list of sink input IDs matching the pattern
    local stream_ids
    stream_ids=$(@pulseaudio@/bin/pactl list sink-inputs short | @gnugrep@/bin/grep -E "$pattern" | @gawk@/bin/awk '{print $1}')

    if [[ -z "$stream_ids" ]]; then
        log "No $description streams found matching '$pattern'."
        return
    fi

    for stream_id in $stream_ids; do
        if [[ -n "$stream_id" ]]; then
            log "Moving $description stream $stream_id to $target_sink"
            if @pulseaudio@/bin/pactl move-sink-input "$stream_id" "$target_sink"; then
                log "Successfully moved stream $stream_id."
            else
                log "Warning: Failed to move stream $stream_id to $target_sink."
            fi
        fi
    done
}

main() {
    log "Preparing audio for streaming..."

    if ! @pulseaudio@/bin/pactl info > /dev/null 2>&1; then
        log "Error: PulseAudio server not available. Cannot prepare audio."
        exit 1
    fi

    # Verify GameAudioSink exists
    if ! @pulseaudio@/bin/pactl list sinks short | @gnugrep@/bin/grep -q "GameAudioSink"; then
        log "Error: GameAudioSink not found. Is the system gaming module enabled and service running?"
        exit 1
    fi

    local physical_sink_target
    physical_sink_target=$(get_physical_sink_name)

    if [[ -z "$physical_sink_target" ]]; then
        log "Warning: Could not determine a physical sink for host bypass apps. They might be routed incorrectly."
    else
        log "Determined physical sink for bypass apps: $physical_sink_target"
    fi

    # Set GameAudioSink as the default sink.
    # New applications (especially games started after this script) will default to GameAudioSink.
    # WirePlumber rules should also enforce this for game apps.
    log "Setting GameAudioSink as the default sink."
    @pulseaudio@/bin/pactl set-default-sink GameAudioSink

    # Move existing game audio streams to GameAudioSink
    move_streams_by_pattern "$GAME_APPS" "GameAudioSink" "game"

    # Keep host applications on physical speakers
    if [[ -n "$HOST_BYPASS_APPS" && -n "$physical_sink_target" ]]; then
        move_streams_by_pattern "$HOST_BYPASS_APPS" "$physical_sink_target" "host bypass"
    elif [[ -n "$HOST_BYPASS_APPS" ]]; then
        log "Warning: HOST_BYPASS_APPS are defined, but no physical sink was found to move them to."
    fi

    log "Audio preparation complete."
}

main "$@"
