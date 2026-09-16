target_dimensions="${target_spec%@*}"
target_refresh="${target_spec##*@}"
target_width="${target_dimensions%x*}"
target_height="${target_dimensions#*x}"
external_seen=0

if [[ "$target_width" =~ ^[0-9]+$ ]] \
  && [[ "$target_height" =~ ^[0-9]+$ ]] \
  && [[ "$target_refresh" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  for ((attempt = 0; attempt < 20; attempt++)); do
    monitors="$(hyprctl -j monitors 2>/dev/null || true)"
    if jq -e 'any(.[]; .name != "eDP-1" and .name != "LVDS-1")' \
      <<<"$monitors" >/dev/null; then
      external_seen=1
    fi

    if jq -e \
        --argjson width "$target_width" \
        --argjson height "$target_height" \
        --argjson refresh "$target_refresh" \
        'any(.[]; .name != "eDP-1" and .name != "LVDS-1"
          and .width == $width and .height == $height
          and ((.refreshRate - $refresh) | fabs) < 1.0)' \
        <<<"$monitors" >/dev/null; then
      exit 0
    fi
    sleep 0.25
  done
fi
