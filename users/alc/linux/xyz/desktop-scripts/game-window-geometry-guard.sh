socket="${XDG_RUNTIME_DIR:?}/hypr/${HYPRLAND_INSTANCE_SIGNATURE:?}/.socket2.sock"
repair_requested="${XDG_RUNTIME_DIR:?}/hyprland-game-window-geometry-guard.requested"
display_requested="$repair_requested.display"
request_lock="$repair_requested.lock"
tolerance=16
provider="$(hyprctl status -j | jq -r '.configProvider // empty')"

repair_geometry() {
  # Launch recovery acts only on the windows that triggered it (newline-
  # separated addresses), or on every watched window for "*". Display
  # recovery always considers every watched window.
  local scope="${2:-*}"
  monitors_json="$(hyprctl monitors -j 2>/dev/null || true)"
  clients_json="$(hyprctl clients -j 2>/dev/null || true)"
  [[ -n "$monitors_json" && -n "$clients_json" ]] || return 0

  while IFS= read -r client_json; do
    address="$(jq -r '.address' <<<"$client_json")"
    if [[ "$scope" != "*" && $'\n'"$scope" != *$'\n'"$address"$'\n'* ]]; then
      continue
    fi
    monitor_id="$(jq -r '.monitor' <<<"$client_json")"
    restore_monitor="$(jq -r '._guardRestoreMonitor' <<<"$client_json")"
    snap_full_height="$(jq -r '._guardSnapFullHeight' <<<"$client_json")"
    center_on_recovery="$(jq -r '._guardCenterOnRecovery' <<<"$client_json")"
    read -r home_x home_y < <(
      jq -r '[(._guardHomeX | tostring), (._guardHomeY | tostring)] | @tsv' <<<"$client_json"
    )
    return_home="$(jq -r '._guardReturnHomeAfterDisplay' <<<"$client_json")"
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
    return_on_success=false
    if [[ "${1:-launch}" == display && "$return_home" == true ]] \
      && ((now <= display_return_until)) \
      && ((now >= display_settle_at)) \
      && [[ $'\n'"$display_returned" != *$'\n'"$address"$'\n'* ]]; then
      # XWayland and Wine can move a window again while the output
      # reconnects, leaving it contained but away from its declared home.
      # Once per display recovery, after the output has stayed unchanged
      # for a few seconds, return such a window home even when contained.
      # The return counts once a move succeeds or the window is already home,
      # so a failed move retries.
      if [[ "$home_x" != null ]]; then
        target_x=$((monitor_x + home_x))
        target_y=$((monitor_y + home_y))
      else
        target_x=$((monitor_x + ((monitor_width - width) / 2)))
        target_y=$((monitor_y + ((monitor_height - height) / 2)))
      fi
      if ((x == target_x && y == target_y)); then
        display_returned+="$address"$'\n'
        continue
      fi
      return_on_success=true
      repair_description="Returned watched window home after the output settled"
    elif [[ "$center_on_recovery" == true && "$home_x" == null ]]; then
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
    elif [[ "$home_x" != null ]]; then
      # A home offset is the declared placement relative to the restore
      # monitor. It applies only to a window left outside the output, in
      # either recovery mode, so contained windows that share the policy's
      # identity (popups, a launcher between titles) are left alone.
      target_x=$((monitor_x + home_x))
      target_y=$((monitor_y + home_y))
      repair_description="Returned watched window to its home position"
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
      [[ "$return_on_success" != true ]] || display_returned+="$address"$'\n'
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
        _guardCenterOnRecovery: ($policy.centerOnRecovery // false),
        _guardHomeX: ($policy.homeOffset.x // null),
        _guardHomeY: ($policy.homeOffset.y // null),
        _guardReturnHomeAfterDisplay: ($policy.returnHomeAfterDisplay // false)
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
          # Keep the event: one that names a watched output arms its home
          # return even when sampling missed the transition.
          {
            flock 9
            printf '%s\n' "$event" >>"$display_requested"
          } 9>"$request_lock"
          ;;
        openwindow\>\>* | windowtitle\>\>* | windowtitlev2\>\>*)
          address="${event#*>>}"
          address="0x${address%%,*}"
          # Titles can change repeatedly in a match. Arm once per matching
          # policy in a window lifetime, not on every title notification,
          # so a window that maps untitled is placed again once its real
          # title selects another policy, but a title that flips back and
          # forth does not re-arm.
          policy_index="$(hyprctl clients -j | jq -r \
            --arg address "$address" --argjson policies "$policies" '
              first(.[] | select(.address == $address) | . as $w |
                $policies | to_entries[] | . as $p |
                select((($w.class // "") | test($p.value.classRegex)) and
                  (($w.title // "") | test($p.value.titleRegex))) |
                $p.key) // empty
            ' 2>/dev/null || true)"
          if [[ -n "$policy_index" && "${identified[$address]:-}" != *",$policy_index,"* ]]; then
            identified[$address]="${identified[$address]:-,}$policy_index,"
            {
              flock 9
              printf '%s\n' "$address" >>"$repair_requested"
            } 9>"$request_lock"
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
  # Events survive a failed monitor query, so a missed transition still
  # counts once sampling recovers.
  local snapshot signature display_event=$pending_display_event
  local watched_change=$pending_watched_change
  local display_events="" event payload field
  local -a fields
  {
    flock 9
    if [[ -e "$display_requested" ]]; then
      display_events="$(<"$display_requested")"
      rm -f "$display_requested"
      display_event=true
    fi
  } 9>"$request_lock"
  while IFS= read -r event; do
    [[ -n "$event" ]] || continue
    payload="${event#*>>}"
    IFS=, read -r -a fields <<<"$payload"
    for field in "${fields[@]}"; do
      if [[ -n "$field" && $'\n'"$watched_outputs"$'\n' == *$'\n'"$field"$'\n'* ]]; then
        watched_change=true
      fi
    done
  done <<<"$display_events"
  # Hyprland can change dpmsStatus without emitting a socket event.
  # Sample output state, not game geometry, while otherwise idle.
  # Failed queries are unknown state: never turn them into fake wakes.
  pending_display_event=$display_event
  pending_watched_change=$watched_change
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
    # The first sample after start records state without arming the home
    # return: startup recovery already places watched windows.
    if [[ "$display_sampled" == true && "$signature" != "$last_display_signature" ]]; then
      watched_change=true
    fi
    display_sampled=true
    pending_display_event=false
    pending_watched_change=false
    if [[ "$signature" != '[]' ]] && {
      [[ "$signature" != "$last_display_signature" ]] || [[ "$display_event" == true ]]
    }; then
      display_until=$((now + 90))
      # Only a change of the watched output itself (its sampled state or an
      # event naming it) restarts the settle delay and the one-time home
      # return; events from other outputs do not.
      # The return is allowed only inside this watched-output recovery, so
      # a later event from another output cannot reuse an expired arm.
      if [[ "$watched_change" == true ]]; then
        display_settle_at=$((now + 5))
        display_returned=""
        display_return_until=$display_until
      fi
      echo "Output available or changed; armed 90-second geometry recovery"
    fi
    last_display_signature="$signature"
  fi
  # The watcher appends under the same lock, so no request is read half
  # written or removed unread. Startup arms its own sweep, so an empty
  # request arms nothing.
  requested=""
  {
    flock 9
    if [[ -e "$repair_requested" ]]; then
      requested="$(<"$repair_requested")"
      rm -f "$repair_requested"
    fi
  } 9>"$request_lock"
  if [[ -n "$requested" ]]; then
    ((now <= launch_until)) || launch_scope=""
    [[ "$launch_scope" == "*" ]] || launch_scope+="$requested"$'\n'
    launch_until=$((now + 10))
  fi
}

watch_geometry_events &
watcher_pid=$!
trap 'kill "$watcher_pid" 2>/dev/null || true; rm -f "$repair_requested" "$request_lock" "$display_requested"' EXIT
trap 'exit 0' HUP INT TERM

# Repair a stale window after service/session startup, then stay active
# briefly after relevant events so delayed XWayland geometry updates are
# caught without continuously policing intentional window placement. The
# startup sweep is armed directly, so an early watcher request cannot narrow it.
launch_until=$((SECONDS + 10))
launch_scope="*"
display_until=0
display_settle_at=0
display_returned=""
display_return_until=-1
display_sampled=false
pending_display_event=false
pending_watched_change=false
watched_outputs="$(jq -r '[.[].restoreMonitor // empty] | unique | .[]' <<<"$policies")"
last_display_signature=""
# Each pass reads the clock once into now, which the functions use, so one
# pass sees one time and the contract test can set it.
while true; do
  now=$SECONDS
  update_recovery_deadlines
  if ((now <= launch_until)); then
    repair_geometry launch "$launch_scope"
  fi
  if ((now <= display_until)); then
    repair_geometry display
  fi
  sleep 1
done
