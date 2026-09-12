{
  config,
  lib,
  pkgs,
  gameWindowGeometryPolicies,
}: let
  mailWorkspaceScript = ''
    workspace=9
    clients="$(hyprctl clients -j 2>/dev/null)"
    jq -e 'type == "array"' <<<"$clients" >/dev/null
    provider="$(hyprctl status -j | jq -r '.configProvider // empty')"

    focus_workspace() {
      if [[ "$provider" == lua ]]; then
        hyprctl eval \
          "hl.dispatch(hl.dsp.focus({ workspace = $workspace }))" \
          >/dev/null
      else
        hyprctl dispatch workspace "$workspace" >/dev/null
      fi
    }

    launch_mail() {
      if [[ "$provider" == lua ]]; then
        hyprctl eval \
          "hl.dispatch(hl.dsp.exec_cmd(\"thunderbird\", { workspace = \"$workspace silent\" }))" \
          >/dev/null
      else
        hyprctl dispatch exec "[workspace $workspace silent] thunderbird" \
          >/dev/null
      fi
    }

    move_window() {
      local address="$1"
      if [[ "$provider" == lua ]]; then
        hyprctl eval \
          "hl.dispatch(hl.dsp.window.move({ workspace = $workspace, window = \"address:$address\", follow = false }))" \
          >/dev/null
      else
        hyprctl dispatch movetoworkspacesilent "$workspace,address:$address" \
          >/dev/null
      fi
    }

    focus_window() {
      local address="$1"
      if [[ "$provider" == lua ]]; then
        hyprctl eval \
          "hl.dispatch(hl.dsp.focus({ window = \"address:$address\" }))" \
          >/dev/null
      else
        hyprctl dispatch focuswindow "address:$address" >/dev/null
      fi
    }

    mapfile -t addresses < <(
      jq -r '
        .[]
        | select(
            .mapped == true
            and (.class == "thunderbird" or .initialClass == "thunderbird")
            and (.address | test("^0x[0-9a-fA-F]+$"))
          )
        | .address
      ' <<<"$clients"
    )

    if ((''${#addresses[@]} == 0)); then
      launch_mail
      focus_workspace
      exit 0
    fi

    for address in "''${addresses[@]}"; do
      move_window "$address" || true
    done
    focus_workspace
    focus_window "''${addresses[0]}" || true
  '';
  mailWorkspace = pkgs.writeShellApplication {
    name = "hyprland-mail-workspace";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.jq
      pkgs.thunderbird
    ];
    text = mailWorkspaceScript;
  };
  closeActiveWindowScript = ''
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
  '';
  closeActiveWindow = pkgs.writeShellApplication {
    name = "hyprland-close-active-window";
    runtimeInputs = [
      pkgs.gawk
      pkgs.hyprland
      pkgs.jq
      pkgs.systemd
    ];
    text = closeActiveWindowScript;
  };
  xwaylandPrimaryOutput = pkgs.writeShellApplication {
    name = "hyprland-xwayland-primary-output";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.hyprland
      pkgs.jq
      pkgs.socat
      pkgs.xrandr
    ];
    text = ''
      socket="''${XDG_RUNTIME_DIR:?}/hypr/''${HYPRLAND_INSTANCE_SIGNATURE:?}/.socket2.sock"
      repair_requested="''${XDG_RUNTIME_DIR:?}/hyprland-xwayland-primary-output.requested"
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
          if DISPLAY="''${DISPLAY:-:0}" xrandr --current 2>/dev/null \
            | grep -q '^DP-1 connected primary '; then
            stable_samples=$((stable_samples + 1))
            if ((stable_samples >= 30)); then
              return 0
            fi
          else
            stable_samples=0
            DISPLAY="''${DISPLAY:-:0}" xrandr --output DP-1 --primary \
              >/dev/null 2>&1 || true
          fi
          sleep 0.1
        done

        echo "Failed to mark DP-1 as the XWayland primary output" >&2
        return 1
      }

      ensure_primary() {
        current_outputs="$(DISPLAY="''${DISPLAY:-:0}" xrandr --current 2>/dev/null || true)"
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
    '';
  };
  gameWindowGeometryGuard = pkgs.writeShellApplication {
    name = "hyprland-game-window-geometry-guard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
      pkgs.socat
    ];
    text = ''
      policies=${lib.escapeShellArg (builtins.toJSON gameWindowGeometryPolicies)}
      socket="''${XDG_RUNTIME_DIR:?}/hypr/''${HYPRLAND_INSTANCE_SIGNATURE:?}/.socket2.sock"
      repair_requested="''${XDG_RUNTIME_DIR:?}/hyprland-game-window-geometry-guard.requested"
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
          [[ "''${1:-launch}" != display ]] || center_on_recovery=false
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
                address="''${event#*>>}"
                address="0x''${address%%,*}"
                # Titles can change repeatedly in a match. Arm once per
                # matching window lifetime, not on every title notification.
                if [[ -z "''${identified[$address]:-}" ]] && hyprctl clients -j | jq -e \
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
                address="0x''${event#*>>}"
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
    '';
  };
  droptermToggle = pkgs.writeShellApplication {
    name = "dropterm-toggle";
    runtimeInputs = [
      config.programs.hyprscratch.package
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
      pkgs.netcat-openbsd
      pkgs.systemd
    ];
    text = ''
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
    '';
  };
in {
  inherit mailWorkspaceScript mailWorkspace closeActiveWindowScript closeActiveWindow xwaylandPrimaryOutput gameWindowGeometryGuard droptermToggle;
}
