socket="${XDG_RUNTIME_DIR:?}/hypr/${HYPRLAND_INSTANCE_SIGNATURE:?}/.socket2.sock"
repair_requested="${XDG_RUNTIME_DIR:?}/hyprland-xwayland-primary-output.requested"
next_server_warning=0

check_output_server() {
  local monitor_names output state connected=false
  monitor_names="$(hyprctl monitors -j 2>/dev/null \
    | jq -er '[.[].name] | select(length > 0) | .[]' 2>/dev/null)" || return 0

  while read -r output state _; do
    [[ "$state" == connected ]] || continue
    connected=true
    if grep -Fxq -- "$output" <<<"$monitor_names"; then
      return 0
    fi
  done <<<"$current_outputs"

  # A missing gaming output is normal during hot-unplug. Warn only
  # when the X server has outputs but none match the live compositor.
  if [[ "$connected" == true ]]; then
    if ((SECONDS >= next_server_warning)); then
      echo "XWayland primary-output repair skipped: X11 outputs do not match Hyprland; check for an X display/socket collision" >&2
      next_server_warning=$((SECONDS + 300))
    fi
    return 1
  fi
}

set_primary() {
  stable_samples=0
  for _ in $(seq 1 150); do
    if DISPLAY="${DISPLAY:-:0}" xrandr --current 2>/dev/null \
      | grep -q '^DP-1 connected primary '; then
      stable_samples=$((stable_samples + 1))
      if ((stable_samples >= 30)); then
        return 0
      fi
    else
      stable_samples=0
      DISPLAY="${DISPLAY:-:0}" xrandr --output DP-1 --primary \
        >/dev/null 2>&1 || true
    fi
    sleep 0.1
  done

  echo "Failed to mark DP-1 as the XWayland primary output" >&2
  return 1
}

ensure_primary() {
  current_outputs="$(DISPLAY="${DISPLAY:-:0}" xrandr --current 2>/dev/null || true)"
  check_output_server || return 0
  if grep -q '^DP-1 connected primary ' <<<"$current_outputs"; then
    return 0
  fi
  if ! grep -q '^DP-1 connected ' <<<"$current_outputs"; then
    return 0
  fi
  set_primary
}

watch_output_events() {
  while true; do
    while IFS= read -r event; do
      case "$event" in
        monitoradded\>\>* | monitoraddedv2\>\>* | dpms\>\>*)
          : >"$repair_requested"
          ;;
      esac
    done < <(socat -U - UNIX-CONNECT:"$socket" 2>/dev/null)
    sleep 1
  done
}

watch_output_events &
watcher_pid=$!
trap 'kill "$watcher_pid" 2>/dev/null || true; rm -f "$repair_requested"' EXIT

: >"$repair_requested"
next_audit=0
while true; do
  now=$SECONDS
  if [[ -e "$repair_requested" ]] || ((now >= next_audit)); then
    rm -f "$repair_requested"
    ensure_primary || true
    next_audit=$((now + 30))
  fi
  sleep 1
done
