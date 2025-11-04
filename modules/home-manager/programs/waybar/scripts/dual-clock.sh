#!/usr/bin/env bash

STATE_FILE="/tmp/dual-clock-state"
[[ ! -f "$STATE_FILE" ]] && echo "time" > "$STATE_FILE"
STATE=$(cat "$STATE_FILE")

if [[ "$STATE" == "time" ]]; then
  OSL_TIME=$(TZ='Europe/Oslo' date +'%H:%M')
  SP_TIME=$(TZ='America/Sao_Paulo' date +'%H:%M')
  TEXT="$OSL_TIME | $SP_TIME"
else
  OSL_DATE=$(TZ='Europe/Oslo' date +'%Y-%m-%d')
  SP_DATE=$(TZ='America/Sao_Paulo' date +'%Y-%m-%d')
  TEXT="$OSL_DATE | $SP_DATE"
fi

HEADER=$(TZ='Europe/Oslo' date +'%A, %B %-d, %Y')
CALENDAR=$(TZ='Europe/Oslo' cal)

TOOLTIP="${HEADER}

${CALENDAR}"

jq -nc \
  --arg text "$TEXT" \
  --arg tooltip "$TOOLTIP" \
  '{text: $text, tooltip: $tooltip}'
