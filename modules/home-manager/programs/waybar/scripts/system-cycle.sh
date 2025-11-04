#!/usr/bin/env bash

STATE_FILE="/tmp/waybar-system-state"
[[ ! -f "$STATE_FILE" ]] && echo "0" > "$STATE_FILE"
STATE=$(cat "$STATE_FILE")

case "$STATE" in
  0)
    USAGE=$(df -h / | awk 'NR==2 {print $5}')
    AVAIL=$(df -h / | awk 'NR==2 {print $4}')
    TOTAL=$(df -h / | awk 'NR==2 {print $2}')
    jq -nc --arg text "$USAGE " \
           --arg tooltip "Disk Usage Available: $AVAIL Total: $TOTAL" \
           '{text: $text, tooltip: $tooltip}'
    ;;
  1)
    MEM_PCT=$(free | awk '/Mem:/ {printf "%.0f%%", $3/$2 * 100}')
    MEM_USED=$(free -h | awk '/Mem:/ {print $3}')
    MEM_TOTAL=$(free -h | awk '/Mem:/ {print $2}')
    jq -nc --arg text "$MEM_PCT " \
           --arg tooltip "Memory Usage Used: $MEM_USED Total: $MEM_TOTAL" \
           '{text: $text, tooltip: $tooltip}'
    ;;
  2)
    IFACE=$(ip route | awk '/default/ {print $5; exit}')
    IP=$(ip -4 addr show "$IFACE" | awk '/inet/ {print $2; exit}')
    GATEWAY=$(ip route | awk '/default/ {print $3; exit}')
    jq -nc --arg text "$IP " \
           --arg tooltip "Network Interface: $IFACE Gateway: $GATEWAY" \
           '{text: $text, tooltip: $tooltip}'
    ;;
esac
