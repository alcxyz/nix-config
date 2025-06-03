#!/usr/bin/env bash
set -euo pipefail

SINK_NAME="GameAudioSink"
SINK_DESC="Virtual Sink for Games and Streaming"

echo "[audio] Creating $SINK_NAME..."

# Simple wait - just check if we can list sinks
wait_count=0
while ! pactl list short sinks >/dev/null 2>&1; do
    if [ $wait_count -gt 15 ]; then
        echo "[audio] Error: Cannot access PulseAudio/PipeWire after 30 seconds"
        exit 1
    fi
    echo "[audio] Waiting for audio system... ($wait_count)"
    sleep 2
    wait_count=$((wait_count + 1))
done

echo "[audio] Audio system ready"

# Check if sink already exists (using pactl since it's more reliable)
if pactl list short sinks | grep -q "$SINK_NAME"; then
    echo "[audio] $SINK_NAME already exists"
    exit 0
fi

echo "[audio] Creating $SINK_NAME..."

# Create using pactl (more reliable than pw-cli for this)
if pactl load-module module-null-sink \
    sink_name="$SINK_NAME" \
    sink_properties="device.description='$SINK_DESC'" \
    rate=48000 \
    channels=2; then
    echo "[audio] $SINK_NAME created successfully"
else
    echo "[audio] Failed to create $SINK_NAME"
    exit 1
fi

# Verify creation
sleep 1
if pactl list short sinks | grep -q "$SINK_NAME"; then
    echo "[audio] $SINK_NAME verified"
else
    echo "[audio] Warning: $SINK_NAME creation could not be verified"
fi
