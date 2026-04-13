#!/bin/bash
# Toggle WezTerm quake-style: show fullscreen / hide
APP="WezTerm"

front=$(osascript -e "tell application \"System Events\" to get name of first application process whose frontmost is true" 2>/dev/null)

if ! osascript -e "tell application \"System Events\" to get name of every application process" 2>/dev/null | grep -q "$APP"; then
  # Not running — launch and fullscreen
  open -a "$APP"
  sleep 0.4
  osascript -e "
    tell application \"System Events\"
      tell process \"$APP\"
        set frontmost to true
        -- Toggle fullscreen via menu
        click menu item \"Toggle Full Screen\" of menu \"View\" of menu bar 1
      end tell
    end tell
  " 2>/dev/null
elif [ "$front" = "$APP" ]; then
  # Focused — hide
  osascript -e "tell application \"$APP\" to set visible of every window to false"
  osascript -e "tell application \"System Events\" to set visible of process \"$APP\" to false"
else
  # Running but not focused — activate
  osascript -e "tell application \"$APP\" to activate"
fi
