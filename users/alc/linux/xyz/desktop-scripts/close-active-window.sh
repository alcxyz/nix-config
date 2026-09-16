active_window="$(hyprctl activewindow -j 2>/dev/null || true)"
active_class="$(jq -r '.class // empty' <<<"$active_window" 2>/dev/null || true)"
active_title="$(jq -r '.title // empty' <<<"$active_window" 2>/dev/null || true)"
active_pid="$(jq -r '.pid // 0' <<<"$active_window" 2>/dev/null || true)"

if [[ "$active_class" == steam_app_default && "$active_title" == Battle.net ]] \
  && [[ "$active_pid" =~ ^[1-9][0-9]*$ ]] \
  && [[ -r "/proc/$active_pid/cgroup" ]]; then
  cgroup="$(awk -F: '$1 == "0" { print $3; exit }' "/proc/$active_pid/cgroup")"
  clients="$(hyprctl clients -j 2>/dev/null || true)"

  if [[ "$cgroup" == */umu-app-battle-net.service ]] \
    && jq -e 'type == "array"' <<<"$clients" >/dev/null 2>&1 \
    && ! jq -e 'any(.[]; .class == "steam_app_default" and .title == "Heroes of the Storm")' \
      <<<"$clients" >/dev/null; then
    # Closing Battle.net's window can leave its Wine runtime behind.
    # Stop only the direct launcher's owning cgroup, and never while a
    # Heroes window is present. All uncertain cases use normal close.
    exec systemctl --user --no-block stop umu-app-battle-net.service
  fi
fi

exec hyprctl dispatch killactive
