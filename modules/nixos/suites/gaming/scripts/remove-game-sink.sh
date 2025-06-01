#!/usr/bin/env bash
set -e
echo "[pipewire-game-sink] Removing GameAudioSink..."
# Ensure pw-cli is available
if ! command -v pw-cli >/dev/null; then
    echo "[pipewire-game-sink] pw-cli command not found. Cannot remove sink." >&2
    exit 1 # Or exit 0 if you prefer it to be non-fatal
fi

SINK_ID=$(pw-cli ls Node 2>/dev/null | grep -B2 'node.name = "GameAudioSink"' | grep 'id:' | awk '{print $2}' | sed 's/,//' | head -n 1)

if [ -n "$SINK_ID" ]; then
  if pw-cli destroy "$SINK_ID" 2>/dev/null; then
    echo "[pipewire-game-sink] GameAudioSink (ID: $SINK_ID) removed."
  else
    echo "[pipewire-game-sink] Failed to destroy GameAudioSink (ID: $SINK_ID). It might have already been removed."
  fi
else
  echo "[pipewire-game-sink] GameAudioSink not found, no action taken."
fi
