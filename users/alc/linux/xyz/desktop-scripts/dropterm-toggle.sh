target_json="$(hyprctl monitors -j | jq -ce '.[] | select(.focused)')"
target_workspace="$(jq -r '.activeWorkspace.id' <<<"$target_json")"
active_is_dropterm="$(
  hyprctl activewindow -j \
    | jq -r '(.initialClass == "dropterm" or .initialTitle == "dropterm") // false'
)"

wait_for_toggle() {
  if [[ "$active_is_dropterm" == true ]]; then
    for _ in $(seq 1 80); do
      if ! hyprctl activewindow -j \
        | jq -e '(.initialClass == "dropterm" or .initialTitle == "dropterm") // false' \
          >/dev/null; then
        return 0
      fi
      sleep 0.025
    done
    return 1
  fi

  client_json=""
  for _ in $(seq 1 80); do
    client_json="$(
      hyprctl clients -j \
        | jq -c --argjson workspace "$target_workspace" \
            '.[] | select(
              (.initialClass == "dropterm" or .initialTitle == "dropterm")
              and .workspace.id == $workspace
            )' \
        | head -n 1
    )"
    [[ -n "$client_json" ]] && return 0
    sleep 0.025
  done
  return 1
}

toggle_dropterm() {
  hyprscratch toggle dropterm >/dev/null 2>&1 || return 1
  wait_for_toggle
}

if ! toggle_dropterm; then
  # Hyprscratch 0.6.5 can leave its main process alive after its
  # Hyprland event thread loses the compositor socket. Recover the stale
  # daemon once, then retry the user's original toggle.
  systemctl --user restart hyprscratch.service

  socket=/tmp/hyprscratch/hyprscratch.sock
  daemon_ready=false
  for _ in $(seq 1 80); do
    if nc -z -U "$socket" >/dev/null 2>&1; then
      daemon_ready=true
      break
    fi
    sleep 0.025
  done

  if [[ "$daemon_ready" != true ]] || ! toggle_dropterm; then
    echo "dropterm toggle failed after restarting hyprscratch" >&2
    exit 1
  fi
fi

# An active dropterm was just hidden; leave its parked geometry alone.
if [[ "$active_is_dropterm" == true ]]; then
  exit 0
fi

address="$(jq -r '.address' <<<"$client_json")"
read -r target_x target_y target_width target_height < <(
  jq -r '[.x, .y, .width, .height] | @tsv' <<<"$target_json"
)
read -r window_width window_height < <(
  jq -r '[.size[0], .size[1]] | @tsv' <<<"$client_json"
)

x=$((target_x + (target_width - window_width) / 2))
y=$((target_y + (target_height - window_height) / 2))
provider="$(hyprctl status -j | jq -r '.configProvider // empty')"
if [[ "$provider" == lua ]]; then
  hyprctl eval \
    "hl.dispatch(hl.dsp.window.move({ x = $x, y = $y, window = \"address:$address\" }))" \
    >/dev/null
  hyprctl eval \
    "hl.dispatch(hl.dsp.focus({ window = \"address:$address\" }))" \
    >/dev/null
else
  hyprctl dispatch movewindowpixel "exact $x $y,address:$address" >/dev/null
  hyprctl dispatch focuswindow "address:$address" >/dev/null
fi
