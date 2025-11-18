#!/usr/bin/env bash
# Detect WM and launch waybar with appropriate config

if pgrep -x hyprland > /dev/null; then
    config_file="$HOME/.config/waybar/config-hyprland.jsonc"
elif pgrep -x niri > /dev/null; then
    config_file="$HOME/.config/waybar/config-niri.jsonc"
else
    # Fallback
    config_file="$HOME/.config/waybar/config-hyprland.jsonc"
fi

waybar -c "$config_file"
