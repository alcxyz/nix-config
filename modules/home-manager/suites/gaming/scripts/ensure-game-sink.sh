# modules/home-manager/suites/gaming/scripts/ensure-game-sink.sh
#!/usr/bin/env bash
set -euo pipefail

SINK_NAME="GameAudioSink"

# Wait for audio system to be ready
wait_count=0
while ! pactl info >/dev/null 2>&1; do
    if [ $wait_count -gt 10 ]; then
        echo "Audio system not ready after 20 seconds"
        exit 1
    fi
    sleep 2
    wait_count=$((wait_count + 1))
done

# Check if sink already exists
if pactl list short sinks | grep -q "$SINK_NAME"; then
    exit 0
fi

# Create the sink
pactl load-module module-null-sink \
    sink_name="$SINK_NAME" \
    sink_properties="device.description='Virtual Sink for Games and Streaming'" \
    rate=48000 \
    channels=2

echo "GameAudioSink created successfully"
