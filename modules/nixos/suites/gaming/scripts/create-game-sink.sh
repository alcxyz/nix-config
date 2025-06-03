#!/usr/bin/env bash
set -euo pipefail

SINK_NAME="GameAudioSink"
SINK_DESC="Virtual Sink for Games and Streaming"

echo "[audio] Creating $SINK_NAME..."

# Better PipeWire readiness check
wait_for_pipewire() {
    local timeout=30
    while [ $timeout -gt 0 ]; do
        # Check multiple conditions for PipeWire readiness
        if command -v pw-cli >/dev/null && \
           pw-cli info >/dev/null 2>&1 && \
           pw-cli list-objects >/dev/null 2>&1 && \
           pactl info >/dev/null 2>&1; then
            echo "[audio] PipeWire is ready"
            return 0
        fi
        echo "[audio] Waiting for PipeWire... ($timeout)"
        sleep 2
        timeout=$((timeout - 2))
    done
    echo "[audio] Timeout waiting for PipeWire"
    return 1
}

# Wait for PipeWire
if ! wait_for_pipewire; then
    echo "[audio] Error: PipeWire not ready after waiting"
    exit 1
fi

# Check if sink already exists
if pw-cli list-objects | grep -q "node.name.*$SINK_NAME"; then
    echo "[audio] $SINK_NAME already exists"
    exit 0
fi

echo "[audio] Creating $SINK_NAME..."

# Create the game audio sink
if pw-cli create-node adapter '{
    factory.name="support.null-audio-sink"
    node.name="'$SINK_NAME'"
    node.description="'$SINK_DESC'"
    media.class="Audio/Sink"
    audio.channels=2
    audio.position="[FL,FR]"
    object.linger=true
    node.dont-remix=true
    node.pause-on-idle=false
}'; then
    echo "[audio] $SINK_NAME created successfully"
else
    echo "[audio] Failed to create $SINK_NAME"
    exit 1
fi

# Verify creation
sleep 2
if pw-cli list-objects | grep -q "node.name.*$SINK_NAME"; then
    echo "[audio] $SINK_NAME verified"
else
    echo "[audio] Warning: $SINK_NAME creation could not be verified"
fi
