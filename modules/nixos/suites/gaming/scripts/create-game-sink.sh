#!/usr/bin/env bash
set -e
echo "[pipewire-game-sink] Waiting for PipeWire..."
timeout=30
# Loop until pw-cli is available and PipeWire is responsive, or timeout
while [ $timeout -gt 0 ]; do
  if command -v pw-cli >/dev/null && pw-cli info &>/dev/null; then
    echo "[pipewire-game-sink] PipeWire is ready."
    break
  fi
  sleep 2
  timeout=$((timeout - 2))
done

if [ $timeout -le 0 ]; then
  echo "[pipewire-game-sink] PipeWire not ready after waiting." >&2
  exit 1
fi

# Check if the sink already exists
if pw-cli ls Node | grep -q 'node.name = "GameAudioSink"'; then
  echo "[pipewire-game-sink] GameAudioSink already exists."
  exit 0
fi

echo "[pipewire-game-sink] Creating GameAudioSink..."
pw-cli create-node adapter '{ factory.name="support.null-audio-sink", node.name="GameAudioSink", node.description="Virtual_Sink_for_Games", media.class="Audio/Sink", audio.channels=2, audio.position="[FL,FR]", object.linger=true, node.dont-remix=true, node.pause-on-idle=false }'
echo "[pipewire-game-sink] GameAudioSink created."
