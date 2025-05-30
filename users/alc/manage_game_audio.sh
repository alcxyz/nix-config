#!/usr/bin/env bash
# users/alc/manage_game_audio.sh

# Placeholder for game audio management script
GAMING_WORKSPACE_NAME="9" # Must match $ws_gaming in hyprland.conf
LOG_FILE="/tmp/game_audio_management.log" # For debugging

# Ensure the log file exists and is writable, or log to journal
# For simplicity, using /tmp for now. Consider a path in XDG_CACHE_HOME.
touch "$LOG_FILE"
chmod 666 "$LOG_FILE" # Make it world-writable for easy debugging if script runs as different user context initially

echo "Script called at $(date)" >> "$LOG_FILE"

# Get current active workspace name/ID using hyprctl and jq
# Ensure jq is installed (added to home.packages in home-linux.nix)
# The path to hyprctl should be in the user's PATH.
ACTIVE_WORKSPACE_NAME=$(hyprctl activeworkspace -j | jq -r '.name') # Or .id if you use numbers for workspace names in rules

echo "Active workspace: $ACTIVE_WORKSPACE_NAME" >> "$LOG_FILE"
echo "Gaming workspace: $GAMING_WORKSPACE_NAME" >> "$LOG_FILE"

# TODO:
# 1. Identify the game's audio stream (e.g., Steam, or the specific game)
#    - Use `pactl list sink-inputs` or `pw-cli dump short Node` and filter by application.name or similar.
# 2. If ACTIVE_WORKSPACE_NAME == GAMING_WORKSPACE_NAME:
#    - Unmute game audio stream (e.g., `pactl set-sink-input-mute <index> 0` or `pw-cli s <id> Props '{ mute: false }'`)
# 3. Else:
#    - Mute game audio stream (e.g., `pactl set-sink-input-mute <index> 1` or `pw-cli s <id> Props '{ mute: true }'`)

if [[ "$ACTIVE_WORKSPACE_NAME" == "$GAMING_WORKSPACE_NAME" ]]; then
  echo "Switched TO gaming workspace. Should UNMUTE game audio." >> "$LOG_FILE"
  # Example: Try to unmute all of Steam (very broad, needs refinement)
  # steam_pids=$(pgrep -x steam) # Get all PIDs for steam
  # if [[ -n "$steam_pids" ]]; then
  #   for steam_pid in $steam_pids; do
  #     # Find sink inputs associated with this PID
  #     pactl list sink-inputs short | grep "process.id = \"$steam_pid\"" | awk '{print $1}' | while read -r id ; do
  #       echo "Unmuting Steam sink input $id" >> "$LOG_FILE"
  #       pactl set-sink-input-mute "$id" 0
  #     done
  #   done
  # fi
else
  echo "Switched AWAY from gaming workspace. Should MUTE game audio." >> "$LOG_FILE"
  # Example: Try to mute all of Steam
  # steam_pids=$(pgrep -x steam)
  # if [[ -n "$steam_pids" ]]; then
  #   for steam_pid in $steam_pids; do
  #     pactl list sink-inputs short | grep "process.id = \"$steam_pid\"" | awk '{print $1}' | while read -r id ; do
  #       echo "Muting Steam sink input $id" >> "$LOG_FILE"
  #       pactl set-sink-input-mute "$id" 1
  #     done
  #   done
  # fi
fi
