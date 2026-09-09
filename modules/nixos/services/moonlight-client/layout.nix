{
  audioOutputControl,
  autoMirrorOutputMode,
  autoMirrorSecondaryPosition,
  autoMirrorTertiaryPosition,
  cfg,
  displayLayoutStateFile,
  dynamicMonitorConfigFile,
  lib,
  mirrorStateFile,
  pkgs,
}: {
  softwareMirror = pkgs.writeShellApplication {
    name = "couch-software-mirror";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.jq
      pkgs.wl-mirror
    ];
    text = ''
      target="$1"
      source="$2"

      while true; do
        monitors="$(hyprctl -j monitors 2>/dev/null || true)"
        if jq -e --arg target "$target" --arg source "$source" \
          'any(.[]; .name == $target) and any(.[]; .name == $source)' \
          <<<"$monitors" >/dev/null 2>&1; then
          wl-mirror \
            --fullscreen-output "$target" \
            --scaling fit \
            --title "Couch mirror $source" \
            "$source" || true
        fi
        sleep 2
      done
    '';
  };

  displayLayoutControl = pkgs.writeShellApplication {
    name = "couch-display-layout";
    runtimeInputs = [
      audioOutputControl
      pkgs.coreutils
      pkgs.hyprland
      pkgs.systemd
    ];
    text = ''
      state_file=${lib.escapeShellArg displayLayoutStateFile}
      current="$(
        if [ -r "$state_file" ]; then
          tr -d '[:space:]' < "$state_file"
        fi
      )"
      case "$current" in
        dual-tvs) current=living-bedroom ;;
        primary-aux) current=living-aux ;;
        secondary-aux) current=bedroom-aux ;;
        solo-primary) current=living ;;
        solo-secondary) current=bedroom ;;
        solo-aux | solo-tertiary) current=aux ;;
        adaptive | all | living-bedroom | living-aux | bedroom-aux | living | bedroom | aux) ;;
        *) current=adaptive ;;
      esac

      case "''${1:-status}" in
        status)
          printf '%s\n' "$current"
          exit 0
          ;;
        cycle)
          case "$current" in
            adaptive) requested=all ;;
            all) requested=living-bedroom ;;
            living-bedroom) requested=living-aux ;;
            living-aux) requested=bedroom-aux ;;
            bedroom-aux) requested=living ;;
            living) requested=bedroom ;;
            bedroom) requested=aux ;;
            *) requested=adaptive ;;
          esac
          ;;
        dual-tvs) requested=living-bedroom ;;
        primary-aux) requested=living-aux ;;
        secondary-aux) requested=bedroom-aux ;;
        solo-primary) requested=living ;;
        solo-secondary) requested=bedroom ;;
        solo-aux | solo-tertiary) requested=aux ;;
        adaptive | all | living-bedroom | living-aux | bedroom-aux | living | bedroom | aux)
          requested="$1"
          ;;
        *)
          echo "usage: couch-display-layout {status|cycle|adaptive|all|living-bedroom|living-aux|bedroom-aux|living|bedroom|aux}" >&2
          exit 2
          ;;
      esac

      ${lib.optionalString cfg.enableAudioOutputCycle ''
        # Migrate live streams before the layout watcher parks the old output.
        # Selecting audio after the HDMI sink disappears is too late for SDL
        # clients such as Moonlight, which keep queuing packets to a dead node.
        timeout --kill-after=1 5 couch-audio-output prepare-layout "$requested" \
          >/dev/null 2>&1 || true
      ''}

      temporary_file="$state_file.tmp"
      printf '%s\n' "$requested" > "$temporary_file"
      mv "$temporary_file" "$state_file"
      ${lib.optionalString cfg.enableAudioOutputCycle ''
        systemctl --user --no-block restart couch-audio-follow-layout.service \
          >/dev/null 2>&1 || true
      ''}
      hyprctl notify 1 3000 'rgb(89b4fa)' "Display layout: $requested" \
        >/dev/null 2>&1 || true
      printf '%s\n' "$requested"
    '';
  };

  couchWorkspace = pkgs.writeShellApplication {
    name = "couch-workspace";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.hyprland
      pkgs.jq
    ];
    text = ''
      config_file=${lib.escapeShellArg dynamicMonitorConfigFile}

      active_workspaces() {
        if [ -r "$config_file" ]; then
          sed -n 's/^workspace = \([0-9][0-9]*\),.*/\1/p' "$config_file" \
            | sort -n -u
        else
          printf '1\n2\n3\n'
        fi
      }

      workspace_is_active() {
        requested="$1"
        active_workspaces | grep -Fxq "$requested"
      }

      adjacent_workspace() {
        direction="$1"
        mapfile -t available < <(active_workspaces)
        if ((''${#available[@]} == 0)); then
          available=(1 2 3)
        fi

        current="$(hyprctl activeworkspace -j | jq -r '.id // 1')"
        current_index=0
        for index in "''${!available[@]}"; do
          if [ "''${available[$index]}" = "$current" ]; then
            current_index="$index"
            break
          fi
        done

        if [ "$direction" = next ]; then
          next_index=$(((current_index + 1) % ''${#available[@]}))
        else
          next_index=$(((current_index + ''${#available[@]} - 1) % ''${#available[@]}))
        fi
        printf '%s\n' "''${available[$next_index]}"
      }

      action="''${1:-switch}"
      target="''${2:-}"
      case "$action" in
        next | previous)
          target="$(adjacent_workspace "$action")"
          action=switch
          ;;
        move-next | move-previous)
          target="$(adjacent_workspace "''${action#move-}")"
          action=move
          ;;
        switch | move)
          if ! workspace_is_active "$target"; then
            hyprctl notify 1 2200 'rgb(f9e2af)' \
              "Workspace $target is not active in this display layout" \
              >/dev/null 2>&1 || true
            exit 1
          fi
          ;;
        *)
          echo "usage: couch-workspace {switch NUMBER|move NUMBER|next|previous|move-next|move-previous}" >&2
          exit 2
          ;;
      esac

      case "$action" in
        switch) exec hyprctl dispatch workspace "$target" ;;
        move) exec hyprctl dispatch movetoworkspace "$target" ;;
      esac
    '';
  };

  displayMirrorToggle = pkgs.writeShellApplication {
    name = "couch-display-mirror";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
    ];
    text = ''
      state_file=${lib.escapeShellArg mirrorStateFile}
      current="$(tr -d '[:space:]' < "$state_file" 2>/dev/null || true)"

      case "''${1:-toggle}" in
        toggle)
          if [ "$current" = 1 ]; then
            requested=0
          else
            requested=1
          fi
          ;;
        on)
          requested=1
          ;;
        off)
          requested=0
          ;;
        status)
          if [ "$current" = 1 ]; then
            echo on
          else
            echo off
          fi
          exit 0
          ;;
        *)
          echo "usage: couch-display-mirror {toggle|on|off|status}" >&2
          exit 2
          ;;
      esac

      if [ "$requested" = 1 ]; then
        external_outputs="$(
          hyprctl -j monitors all 2>/dev/null \
            | jq '[.[] | select(
                .name != "eDP-1" and .name != "LVDS-1"
                and .disabled == false and .dpmsStatus == true
              )] | length' 2>/dev/null \
            || printf '0\n'
        )"
        if [ "$external_outputs" -lt 2 ]; then
          echo "display mirroring requires two connected external outputs" >&2
          exit 1
        fi
      fi

      temporary_file="$state_file.tmp"
      printf '%s\n' "$requested" > "$temporary_file"
      mv "$temporary_file" "$state_file"
    '';
  };

  autoLayoutExternalOutputs = pkgs.writeShellApplication {
    name = "couch-auto-layout-outputs";
    runtimeInputs =
      [
        pkgs.coreutils
        pkgs.hyprland
        pkgs.jq
        pkgs.xrandr
      ]
      ++ lib.optional (cfg.autoMirrorExternalOutputs || cfg.enableMirrorToggle) pkgs.wl-mirror;
    text = ''
      config_file=${lib.escapeShellArg dynamicMonitorConfigFile}
      mirror_state_file=${lib.escapeShellArg mirrorStateFile}
      display_layout_state_file=${lib.escapeShellArg displayLayoutStateFile}
      layout_key=""
      mirror_pid=""

      stop_mirror() {
        if [ -n "$mirror_pid" ] && kill -0 "$mirror_pid" 2>/dev/null; then
          kill "$mirror_pid" 2>/dev/null || true
          wait "$mirror_pid" 2>/dev/null || true
        fi
        mirror_pid=""
      }

      mode_available() {
        output="$1"
        candidate="$2"
        case "$candidate" in
          *@[0-9]*) ;;
          *) return 1 ;;
        esac
        dimensions="''${candidate%@*}"
        refresh="''${candidate##*@}"
        jq -e \
          --arg output "$output" \
          --arg dimensions "$dimensions" \
          --argjson refresh "$refresh" '
            [.[] | select(.name == $output)][0].availableModes // []
            | any(.[];
                startswith($dimensions + "@")
                and (
                  try (
                    (capture("@(?<refresh>[0-9.]+)Hz$").refresh | tonumber) - $refresh
                    | fabs < 1.0
                  ) catch false
                )
              )
          ' <<<"$monitors" >/dev/null
      }

      select_auxiliary_mode() {
        output="$1"
        for candidate in ${lib.escapeShellArgs cfg.autoLayoutSecondaryModes}; do
          if mode_available "$output" "$candidate"; then
            printf '%s\n' "$candidate"
            return
          fi
        done
        printf '%s\n' preferred
      }

      restore_secondary_workspace() {
        target_output="$1"
        [ -n "$target_output" ] || return
        hyprctl dispatch focusmonitor "$target_output" >/dev/null 2>&1 || true
        hyprctl dispatch workspace \
          ${lib.escapeShellArg (toString (builtins.head cfg.autoLayoutSecondaryWorkspaces))} \
          >/dev/null 2>&1 || true
      }

      write_layout() {
        source_output="$1"
        source_mode="$2"
        secondary_output="$3"
        secondary_mode="$4"
        tertiary_output="$5"
        tertiary_mode="$6"
        native_mirror="$7"
        secondary_logical=0
        if [ -n "$secondary_output" ] && [ "$native_mirror_requested" != 1 ]; then
          secondary_logical=1
        fi
        allowed_workspaces=${lib.escapeShellArg (builtins.toJSON cfg.autoLayoutPrimaryWorkspaces)}
        if [ "$secondary_logical" = 1 ]; then
          allowed_workspaces="$(
            jq -cn \
              --argjson primary "$allowed_workspaces" \
              --argjson secondary ${lib.escapeShellArg (builtins.toJSON cfg.autoLayoutSecondaryWorkspaces)} \
              '$primary + $secondary'
          )"
        fi
        if [ -n "$tertiary_output" ]; then
          tertiary_workspaces=${lib.escapeShellArg (builtins.toJSON cfg.autoLayoutTertiaryWorkspaces)}
          if [ "$secondary_logical" != 1 ]; then
            # Compact a two-display layout into the first two workspace blocks.
            # The auxiliary output is physically tertiary, but logically it is
            # the second active display when no second TV is selected.
            tertiary_workspaces=${lib.escapeShellArg (builtins.toJSON cfg.autoLayoutSecondaryWorkspaces)}
          fi
          allowed_workspaces="$(
            jq -cn \
              --argjson current "$allowed_workspaces" \
              --argjson tertiary "$tertiary_workspaces" \
              '$current + $tertiary'
          )"
        fi
        temporary_file="$config_file.tmp"
        secondary_position=${lib.escapeShellArg cfg.autoLayoutSecondaryPosition}
        tertiary_position=${lib.escapeShellArg cfg.autoLayoutTertiaryPosition}
        if [ -z "$secondary_output" ] && [ -n "$tertiary_output" ]; then
          tertiary_position=${lib.escapeShellArg cfg.autoLayoutSecondaryPosition}
        elif [ "$native_mirror_requested" = 1 ]; then
          secondary_position=${lib.escapeShellArg autoMirrorSecondaryPosition}
          tertiary_position=${lib.escapeShellArg autoMirrorTertiaryPosition}
        fi
        if [ "$native_mirror" = 1 ]; then
          tertiary_position=${lib.escapeShellArg autoMirrorSecondaryPosition}
        fi

        {
          parked_index=1
          while IFS= read -r parked_output; do
            parked_mode="$(select_auxiliary_mode "$parked_output")"
            parked_position="$((parked_index * 10000))x0"
            printf 'monitor = %s, %s, %s, 1\n' \
              "$parked_output" "$parked_mode" "$parked_position"
            parked_index=$((parked_index + 1))
          done < <(jq -r '.[].name' <<<"$parked_outputs")

          if [ -n "$source_output" ]; then
            printf 'monitor = %s, %s, 0x0, %s\n' \
              "$source_output" \
              "$source_mode" \
              ${lib.escapeShellArg (toString cfg.outputScale)}
            for workspace in ${lib.escapeShellArgs (map toString cfg.autoLayoutPrimaryWorkspaces)}; do
              default=""
              if [ "$workspace" = ${lib.escapeShellArg (toString (builtins.head cfg.autoLayoutPrimaryWorkspaces))} ]; then
                default=", default:true"
              fi
              printf 'workspace = %s, monitor:%s, persistent:true%s\n' \
                "$workspace" "$source_output" "$default"
            done
          fi
          if [ -n "$secondary_output" ]; then
            if [ "$native_mirror" = 1 ]; then
              printf 'monitor = %s, %s, 0x0, %s, mirror, %s\n' \
                "$secondary_output" \
                "$secondary_mode" \
                ${lib.escapeShellArg (toString cfg.autoLayoutSecondaryScale)} \
                "$source_output"
            elif [ "$secondary_logical" = 1 ]; then
              printf 'monitor = %s, %s, %s, %s\n' \
                "$secondary_output" \
                "$secondary_mode" \
                "$secondary_position" \
                ${lib.escapeShellArg (toString cfg.autoLayoutSecondaryScale)}
              for workspace in ${lib.escapeShellArgs (map toString cfg.autoLayoutSecondaryWorkspaces)}; do
                default=""
                if [ "$workspace" = ${lib.escapeShellArg (toString (builtins.head cfg.autoLayoutSecondaryWorkspaces))} ]; then
                  default=", default:true"
                fi
                printf 'workspace = %s, monitor:%s, persistent:true%s\n' \
                  "$workspace" "$secondary_output" "$default"
              done
            else
              printf 'monitor = %s, %s, %s, %s\n' \
                "$secondary_output" \
                "$secondary_mode" \
                "$secondary_position" \
                ${lib.escapeShellArg (toString cfg.autoLayoutSecondaryScale)}
            fi
          fi
          if [ -n "$tertiary_output" ]; then
            printf 'monitor = %s, %s, %s, %s\n' \
              "$tertiary_output" \
              "$tertiary_mode" \
              "$tertiary_position" \
              ${lib.escapeShellArg (toString cfg.autoLayoutTertiaryScale)}
            tertiary_default_workspace="$(jq -r '.[0]' <<<"$tertiary_workspaces")"
            while read -r workspace; do
              default=""
              if [ "$workspace" = "$tertiary_default_workspace" ]; then
                default=", default:true"
              fi
              printf 'workspace = %s, monitor:%s, persistent:true%s\n' \
                "$workspace" "$tertiary_output" "$default"
            done < <(jq -r '.[]' <<<"$tertiary_workspaces")
          fi
        } >"$temporary_file"

        if ! cmp -s "$temporary_file" "$config_file"; then
          mv "$temporary_file" "$config_file"
          hyprctl reload >/dev/null 2>&1 || true
          sleep 0.5
        else
          rm -f "$temporary_file"
        fi

        while IFS= read -r parked_output; do
          hyprctl dispatch dpms off "$parked_output" >/dev/null 2>&1 || true
        done < <(jq -r '.[].name' <<<"$parked_outputs")
        while IFS= read -r active_output; do
          hyprctl dispatch dpms on "$active_output" >/dev/null 2>&1 || true
        done < <(jq -r '.[].name' <<<"$external_monitors")

        if [ -n "$source_output" ]; then
          for workspace in ${lib.escapeShellArgs (map toString cfg.autoLayoutPrimaryWorkspaces)}; do
            hyprctl dispatch moveworkspacetomonitor \
              "$workspace" "$source_output" >/dev/null 2>&1 || true
          done
        fi
        if [ "$secondary_logical" = 1 ]; then
          hyprctl dispatch focusmonitor "$secondary_output" >/dev/null 2>&1 || true
          hyprctl dispatch workspace \
            ${lib.escapeShellArg (toString (builtins.head cfg.autoLayoutSecondaryWorkspaces))} \
            >/dev/null 2>&1 || true
          for workspace in ${lib.escapeShellArgs (map toString cfg.autoLayoutSecondaryWorkspaces)}; do
            hyprctl dispatch moveworkspacetomonitor \
              "$workspace" "$secondary_output" >/dev/null 2>&1 || true
          done
        fi
        if [ -n "$tertiary_output" ]; then
          hyprctl dispatch focusmonitor "$tertiary_output" >/dev/null 2>&1 || true
          tertiary_default_workspace="$(jq -r '.[0]' <<<"$tertiary_workspaces")"
          hyprctl dispatch workspace \
            "$tertiary_default_workspace" \
            >/dev/null 2>&1 || true
          while read -r workspace; do
            hyprctl dispatch moveworkspacetomonitor \
              "$workspace" "$tertiary_output" >/dev/null 2>&1 || true
          done < <(jq -r '.[]' <<<"$tertiary_workspaces")
        fi
        if [ -n "$source_output" ]; then
          while IFS=$'\t' read -r address destination; do
            [ -n "$address" ] || continue
            hyprctl dispatch movetoworkspacesilent \
              "$destination,address:$address" >/dev/null 2>&1 || true
          done < <(
            hyprctl clients -j \
              | jq -r --argjson allowed "$allowed_workspaces" '
                  .[]
                  | .workspace.id as $id
                  | select(
                      $id > 0
                      and $id < 10
                      and ($allowed | index($id) | not)
                    )
                  | [.address, (((.workspace.id - 1) % 3) + 1)]
                  | @tsv
                '
          )
          hyprctl dispatch focusmonitor "$source_output" >/dev/null 2>&1 || true
          hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
          DISPLAY=:0 xrandr --output "$source_output" --primary >/dev/null 2>&1 || true
        fi
      }

      trap stop_mirror EXIT
      trap 'exit 0' HUP INT TERM

      while true; do
        monitors="$(hyprctl -j monitors all 2>/dev/null || printf '[]')"
        connected_external_monitors="$(
          jq -c '[.[] | select(
            .name != "eDP-1" and .name != "LVDS-1" and .disabled == false
          )]' <<<"$monitors" 2>/dev/null || printf '[]'
        )"

        display_layout=all
        ${lib.optionalString cfg.enableAdaptiveDisplayLayout ''
        display_layout="$(tr -d '[:space:]' < "$display_layout_state_file" 2>/dev/null || true)"
        case "$display_layout" in
          dual-tvs) display_layout=living-bedroom ;;
          primary-aux) display_layout=living-aux ;;
          secondary-aux) display_layout=bedroom-aux ;;
          solo-primary) display_layout=living ;;
          solo-secondary) display_layout=bedroom ;;
          solo-aux | solo-tertiary) display_layout=aux ;;
          adaptive | all | living-bedroom | living-aux | bedroom-aux | living | bedroom | aux) ;;
          *) display_layout=adaptive ;;
        esac
      ''}

        case "$display_layout" in
          adaptive)
            external_monitors="$(
              jq -c '
                [.[] | select(.dpmsStatus == true)]
                | sort_by(.physicalWidth * .physicalHeight)
                | reverse
                | .[:1]
              ' <<<"$connected_external_monitors"
            )"
            # An empty external layout is never valid. If no output is already
            # enabled, retain the physically largest connected output as the
            # primary fallback.
            if [ "$(jq 'length' <<<"$external_monitors")" -eq 0 ]; then
              external_monitors="$(
                jq -c '
                  sort_by(.physicalWidth * .physicalHeight)
                  | reverse
                  | .[:1]
                ' <<<"$connected_external_monitors"
              )"
            fi
            ;;
          all)
            external_monitors="$connected_external_monitors"
            ;;
          living-bedroom)
            external_monitors="$(
              jq -c \
                --argjson minimum_width ${lib.escapeShellArg (toString cfg.autoLayoutPrimaryMinPhysicalWidth)} '
                if length == 0 then []
                else
                  (sort_by(.physicalWidth * .physicalHeight) | reverse) as $ranked
                  | ([$ranked[] | select(.physicalWidth >= $minimum_width)]) as $tvs
                  | if ($tvs | length) > 0 then $tvs[:2]
                    else $ranked[:1]
                    end
                end
              ' <<<"$connected_external_monitors"
            )"
            ;;
          living-aux | bedroom-aux)
            external_monitors="$(
              jq -c \
                --arg layout "$display_layout" \
                --argjson minimum_width ${lib.escapeShellArg (toString cfg.autoLayoutPrimaryMinPhysicalWidth)} '
                if length == 0 then []
                else
                  (sort_by(.physicalWidth * .physicalHeight) | reverse) as $ranked
                  | ([$ranked[] | select(.physicalWidth >= $minimum_width)]) as $tvs
                  | ([$ranked[] | select(.physicalWidth < $minimum_width)]) as $auxiliary
                  | (if $layout == "living-aux" then
                       ($tvs[0] // $ranked[0])
                     else
                       ($tvs[1] // $tvs[0] // $ranked[0])
                     end) as $tv
                  | [$tv, $auxiliary[0]]
                  | map(select(. != null))
                  | unique_by(.name)
                end
              ' <<<"$connected_external_monitors"
            )"
            ;;
          living | bedroom | aux)
            external_monitors="$(
              jq -c \
                --arg layout "$display_layout" \
                --argjson minimum_width ${lib.escapeShellArg (toString cfg.autoLayoutPrimaryMinPhysicalWidth)} '
                if length == 0 then []
                else
                  (sort_by(.physicalWidth * .physicalHeight) | reverse) as $ranked
                  | ([$ranked[] | select(.physicalWidth >= $minimum_width)]) as $tvs
                  | ([$ranked[] | select(.physicalWidth < $minimum_width)]) as $auxiliary
                  | if $layout == "living" then
                      [($tvs[0] // $ranked[0])]
                    elif $layout == "bedroom" then
                      [($tvs[1] // $tvs[0] // $ranked[0])]
                    else
                      [($auxiliary[0] // $tvs[0] // $ranked[0])]
                    end
                end
              ' <<<"$connected_external_monitors"
            )"
            ;;
        esac

        active_output_names="$(jq -c '[.[].name]' <<<"$external_monitors")"
        parked_outputs="$(
          jq -c --argjson active "$active_output_names" '
            [.[] | select(.name as $name | ($active | index($name) | not))]
          ' <<<"$connected_external_monitors"
        )"
        source_output="$(
          jq -r --argjson minimum_width ${lib.escapeShellArg (toString cfg.autoLayoutPrimaryMinPhysicalWidth)} '
            if length == 0 then ""
            else
              (map(select(.physicalWidth >= $minimum_width))) as $preferred
              | (if ($preferred | length) > 0 then $preferred else . end)
              | max_by(.physicalWidth * .physicalHeight)
              | .name
            end
          ' <<<"$external_monitors"
        )"
        secondary_output=""
        secondary_mode=""
        tertiary_output=""
        tertiary_mode=""
        source_mode=""
        if [ -n "$source_output" ]; then
          source_mode="$(select_auxiliary_mode "$source_output")"
          secondary_output="$(
            jq -r \
              --arg source "$source_output" \
              --argjson minimum_width ${lib.escapeShellArg (toString cfg.autoLayoutPrimaryMinPhysicalWidth)} '
              [.[] | select(
                .name != $source and .physicalWidth >= $minimum_width
              )]
              | max_by(.physicalWidth * .physicalHeight).name // ""
            ' <<<"$external_monitors"
          )"
          tertiary_output="$(
            jq -r \
              --arg source "$source_output" \
              --argjson minimum_width ${lib.escapeShellArg (toString cfg.autoLayoutPrimaryMinPhysicalWidth)} '
              [.[] | select(
                .name != $source and .physicalWidth < $minimum_width
              )]
              | max_by(.physicalWidth * .physicalHeight).name // ""
            ' <<<"$external_monitors"
          )"
          if [ -n "$secondary_output" ]; then
            secondary_mode="$(select_auxiliary_mode "$secondary_output")"
          fi
          if [ -n "$tertiary_output" ]; then
            tertiary_mode="$(select_auxiliary_mode "$tertiary_output")"
          fi
        fi

        native_mirror_requested=0
        ${lib.optionalString cfg.enableMirrorToggle ''
        native_mirror_requested="$(tr -d '[:space:]' < "$mirror_state_file" 2>/dev/null || true)"
        if [ "$native_mirror_requested" != 1 ]; then
          native_mirror_requested=0
        fi
      ''}
        mirror_output_mode=${lib.escapeShellArg autoMirrorOutputMode}
        if [ "$native_mirror_requested" = 1 ] \
          && [ -n "$mirror_output_mode" ] \
          && [ -n "$source_output" ] \
          && [ -n "$secondary_output" ] \
          && mode_available "$source_output" "$mirror_output_mode" \
          && mode_available "$secondary_output" "$mirror_output_mode"; then
          source_mode="$mirror_output_mode"
          secondary_mode="$mirror_output_mode"
        fi
        native_mirror=0
        native_mirror_allowed=${
        if cfg.forceSoftwareMirror
        then "0"
        else "1"
      }
        primary_dimensions="''${source_mode%@*}"
        secondary_dimensions="''${secondary_mode%@*}"
        if [ "$native_mirror_requested" = 1 ] \
          && [ "$native_mirror_allowed" = 1 ] \
          && [ -n "$secondary_output" ] \
          && [ "$secondary_dimensions" = "$primary_dimensions" ]; then
          native_mirror=1
        fi

        parked_output_names="$(jq -r '[.[].name] | join(",")' <<<"$parked_outputs")"
        new_layout_key="$display_layout:$source_output:$source_mode:$secondary_output:$secondary_mode:$tertiary_output:$tertiary_mode:$parked_output_names:$native_mirror"
        if [ "$new_layout_key" != "$layout_key" ]; then
          stop_mirror
          write_layout \
            "$source_output" \
            "$source_mode" \
            "$secondary_output" \
            "$secondary_mode" \
            "$tertiary_output" \
            "$tertiary_mode" \
            "$native_mirror"
          layout_key="$new_layout_key"
        fi

        ${lib.optionalString (cfg.autoMirrorExternalOutputs || cfg.enableMirrorToggle) ''
        software_mirror=0
        ${lib.optionalString cfg.autoMirrorExternalOutputs ''
          software_mirror=1
        ''}
        ${lib.optionalString cfg.enableMirrorToggle ''
          if [ "$native_mirror_requested" = 1 ] && [ "$native_mirror" != 1 ]; then
            software_mirror=1
          fi
        ''}

        if [ "$software_mirror" = 1 ] \
          && [ -n "$source_output" ] \
          && [ -n "$secondary_output" ]; then
          if [ -z "$mirror_pid" ] || ! kill -0 "$mirror_pid" 2>/dev/null; then
            hyprctl dispatch focusmonitor "$secondary_output" >/dev/null 2>&1 || true
            hyprctl dispatch workspace \
              ${lib.escapeShellArg (toString cfg.autoMirrorWorkspace)} \
              >/dev/null 2>&1 || true
            wl-mirror \
              --fullscreen-output "$secondary_output" \
              --scaling fit \
              --title "Couch mirror $source_output" \
              "$source_output" &
            mirror_pid=$!
            sleep 0.5
            hyprctl dispatch focusmonitor "$source_output" >/dev/null 2>&1 || true
            hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
          fi
        elif [ -n "$mirror_pid" ]; then
          stop_mirror
          restore_secondary_workspace "$secondary_output"
          if [ -n "$source_output" ]; then
            hyprctl dispatch focusmonitor "$source_output" >/dev/null 2>&1 || true
            hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
          fi
        fi
      ''}

        sleep 1
      done
    '';
  };
}
