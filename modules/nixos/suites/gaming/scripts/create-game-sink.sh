#!/usr/bin/env bash
# scripts/create-game-sink.sh
set -euo pipefail

SINK_NAME="GameAudioSink"
SINK_DESC="Virtual Sink for Games and Streaming"

echo "[audio] Creating $SINK_NAME..."

# Wait for PipeWire to be ready
timeout=10
while [ $timeout -gt 0 ] && ! pw-cli info &>/dev/null; do
    sleep 1
    timeout=$((timeout - 1))
done

if [ $timeout -le 0 ]; then
    echo "[audio] Error: PipeWire not ready"
    exit 1
fi

# Check if sink already exists
if pw-cli list-objects | grep -q "node.name.*$SINK_NAME"; then
    echo "[audio] $SINK_NAME already exists"
    exit 0
fi

# Create the game audio sink
pw-cli create-node adapter '{
    factory.name="support.null-audio-sink"
    node.name="'$SINK_NAME'"
    node.description="'$SINK_DESC'"
    media.class="Audio/Sink"
    audio.channels=2
    audio.position="[FL,FR]"
    object.linger=true
    node.dont-remix=true
    node.pause-on-idle=false
}'

echo "[audio] $SINK_NAME created successfully"
