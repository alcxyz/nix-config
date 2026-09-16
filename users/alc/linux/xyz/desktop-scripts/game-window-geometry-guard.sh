socket="${XDG_RUNTIME_DIR:?}/hypr/${HYPRLAND_INSTANCE_SIGNATURE:?}/.socket2.sock"
repair_requested="${XDG_RUNTIME_DIR:?}/hyprland-game-window-geometry-guard.requested"
display_requested="$repair_requested.display"
tolerance=16
provider="$(hyprctl status -j | jq -r '.configProvider // empty')"

repair_geometry() {
  monitors_json="$(hyprctl monitors -j 2>/dev/null || true)"
  clients_json="$(hyprctl clients -j 2>/dev/null || true)"
  [[ -n "$monitors_json" && -n "$clients_json" ]] || return 0

  while IFS= read -r client_json; do
    address="$(jq -r '.address' <<<"$client_json")"
    monitor_id="$(jq -r '.monitor' <<<"$client_json")"
    restore_monitor="$(jq -r '._guardRestoreMonitor' <<<"$client_json")"
    snap_full_height="$(jq -r '._guardSnapFullHeight' <<<"$client_json")"
    center_on_recovery="$(jq -r '._guardCenterOnRecovery' <<<"$client_json")"
    # The longer wake window repairs containment/edge drift only. It
    # must not repeatedly center intentional in-monitor positioning.
    [[ "${1:-launch}" != display ]] || center_on_recovery=false
    monitor_json="$(
      if [[ "$restore_monitor" == null ]]; then
        jq -ce --argjson id "$monitor_id" \
          '.[] | select(.id == $id and .dpmsStatus == true)' \
          <<<"$monitors_json" || true
      else
        jq -ce --arg name "$restore_monitor" \
          '.[] | select(.name == $name and .dpmsStatus == true)' \
          <<<"$monitors_json" || true
      fi
    )"
    [[ -n "$monitor_json" ]] || continue
    # Never move a window across outputs behind its workspace's back.
    [[ "$(jq -r '.id' <<<"$monitor_json")" == "$monitor_id" ]] || continue

    read -r x y width height < <(
      jq -r '[.at[0], .at[1], .size[0], .size[1]] | @tsv' \
        <<<"$client_json"
    )
    read -r monitor_x monitor_y monitor_width monitor_height < <(
      jq -r '[.x, .y, .width, .height] | @tsv' <<<"$monitor_json"
    )

    # Do not attempt to contain a deliberately oversized window.
    if ((
      width > monitor_width + (2 * tolerance)
      || height > monitor_height + (2 * tolerance)
    )); then
      continue
    fi

    repair_description=""
    if [[ "$center_on_recovery" == true ]]; then
      target_x=$((monitor_x + ((monitor_width - width) / 2)))
      target_y=$((monitor_y + ((monitor_height - height) / 2)))
      ((x != target_x || y != target_y)) || continue
      repair_description="Centered watched window after lifecycle event"
    elif [[ "$snap_full_height" == true ]] && ((
      height == monitor_height
      && y != monitor_y
      && y >= monitor_y - tolerance
      && y <= monitor_y + tolerance
      && x >= monitor_x - tolerance
      && x + width <= monitor_x + monitor_width + tolerance
    )); then
      # XWayland can restore a monitor-height borderless game a few
      # pixels above the output after DPMS. Preserve its horizontal
      # placement and size; correct only the exposed vertical edge.
      target_x=$x
      target_y=$monitor_y
      repair_description="Snapped full-height watched window"
    elif ((
      x >= monitor_x - tolerance
      && y >= monitor_y - tolerance
      && x + width <= monitor_x + monitor_width + tolerance
      && y + height <= monitor_y + monitor_height + tolerance
    )); then
      continue
    else
      target_x=$((monitor_x + ((monitor_width - width) / 2)))
      target_y=$((monitor_y + ((monitor_height - height) / 2)))
      repair_description="Recentered watched window"
    fi

    if [[ "$provider" == lua ]]; then
      move_result="$(hyprctl eval \
        "hl.dispatch(hl.dsp.window.move({ x = $target_x, y = $target_y, window = \"address:$address\" }))" \
        2>&1 || true)"
    else
      move_result="$(hyprctl dispatch movewindowpixel \
        "exact $target_x $target_y,address:$address" 2>&1 || true)"
    fi
    if [[ "$move_result" == ok* ]]; then
      echo "$repair_description $address on monitor $monitor_id"
    else
      echo "Failed to recenter watched window $address: $move_result" >&2
    fi
  done < <(
    jq -c --argjson policies "$policies" '
      .[] | . as $window |
      ([$policies[] | . as $policy | select(
        (($policy.classRegex == null)
          or (($window.class // "") | test($policy.classRegex)))
        and (($policy.titleRegex == null)
          or (($window.title // "") | test($policy.titleRegex)))
        and (($policy.initialClassRegex == null)
          or (($window.initialClass // "") | test($policy.initialClassRegex)))
        and (($policy.initialTitleRegex == null)
          or (($window.initialTitle // "") | test($policy.initialTitleRegex)))
      )] | first) as $policy |
      select(
        $policy != null
        and (($policy.workspace == null) or (.workspace.id == $policy.workspace))
        and .mapped == true
        and .hidden == false
        and .floating == true
        and ((.fullscreen // 0) == 0)
      ) |
      . + {
        _guardRestoreMonitor: ($policy.restoreMonitor // null),
        _guardSnapFullHeight: ($policy.snapFullHeight // false),
        _guardCenterOnRecovery: ($policy.centerOnRecovery // false)
      }
    ' <<<"$clients_json"
  )
}

watch_geometry_events() {
  declare -A identified=()
  while true; do
    while IFS= read -r event; do
      case "$event" in
        monitoradded\>\>* | monitoraddedv2\>\>* \
          | monitorremoved\>\>* | monitorremovedv2\>\>* \
          | dpms\>\>*)
          : >"$display_requested"
          ;;
        openwindow\>\>* | windowtitle\>\>* | windowtitlev2\>\>*)
          address="${event#*>>}"
          address="0x${address%%,*}"
          # Titles can change repeatedly in a match. Arm once per
          # matching window lifetime, not on every title notification.
          if [[ -z "${identified[$address]:-}" ]] && hyprctl clients -j | jq -e \
            --arg address "$address" --argjson policies "$policies" '
              any(.[]; . as $w | .address == $address and
                any($policies[]; . as $p |
                  ($w.class | test($p.classRegex)) and
                  ($w.title | test($p.titleRegex))))
            ' >/dev/null; then
            identified[$address]=1
            : >"$repair_requested"
          fi
          ;;
        closewindow\>\>*)
          address="0x${event#*>>}"
          unset 'identified[$address]'
          ;;
      esac
    done < <(socat -U - UNIX-CONNECT:"$socket" 2>/dev/null)
    sleep 1
  done
}

update_recovery_deadlines() {
  local snapshot signature display_event=false
  if [[ -e "$display_requested" ]]; then
    rm -f "$display_requested"
    display_event=true
  fi
  # Hyprland can change dpmsStatus without emitting a socket event.
  # Sample output state, not game geometry, while otherwise idle.
  # Failed queries are unknown state: never turn them into fake wakes.
  if snapshot="$(hyprctl monitors -j 2>/dev/null)" && signature="$(
    jq -ce --argjson policies "$policies" '
      if type != "array" then error("invalid monitor snapshot") else
        [.[] | . as $m | select(any($policies[];
          .restoreMonitor == null or .restoreMonitor == $m.name)) |
          select(.dpmsStatus == true) |
          {name, id, x, y, width, height, scale}] | sort_by(.name)
      end
    ' <<<"$snapshot" 2>/dev/null
  )"; then
    if [[ "$signature" != '[]' ]] && {
      [[ "$signature" != "$last_display_signature" ]] || [[ "$display_event" == true ]]
    }; then
      display_until=$((SECONDS + 90))
      echo "Output available or changed; armed 90-second geometry recovery"
    fi
    last_display_signature="$signature"
  fi
  if [[ -e "$repair_requested" ]]; then
    rm -f "$repair_requested"
    launch_until=$((SECONDS + 10))
  fi
}

watch_geometry_events &
watcher_pid=$!
trap 'kill "$watcher_pid" 2>/dev/null || true; rm -f "$repair_requested" "$display_requested"' EXIT
trap 'exit 0' HUP INT TERM

# Repair a stale window after service/session startup, then stay active
# briefly after relevant events so delayed XWayland geometry updates are
# caught without continuously policing intentional window placement.
: >"$repair_requested"
launch_until=0
display_until=0
last_display_signature=""
while true; do
  update_recovery_deadlines
  if ((SECONDS <= launch_until)); then
    repair_geometry launch
  elif ((SECONDS <= display_until)); then
    repair_geometry display
  fi
  sleep 1
done
