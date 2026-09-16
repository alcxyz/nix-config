systemctl --user start pipewire.service wireplumber.service pipewire-pulse.socket \
  >/dev/null 2>&1 || true

for ((attempt = 0; attempt < 20; attempt++)); do
  while read -r card; do
    pactl set-card-profile "$card" output:hdmi-stereo >/dev/null 2>&1 || true
  done < <(pactl list short cards 2>/dev/null | awk '{ print $2 }')

  sink="$(pactl list short sinks 2>/dev/null | awk '$2 ~ /hdmi/ { print $2; exit }')"
  if [ -n "$sink" ]; then
    pactl set-default-sink "$sink"
    exit 0
  fi
  sleep 0.5
done

exit 1
