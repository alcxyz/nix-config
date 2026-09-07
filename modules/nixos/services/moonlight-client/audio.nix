{
  cfg,
  lib,
  pkgs,
  displayLayoutStateFile,
  modeStateFile,
  waitForStableOutputs,
}: let
  audioOutputControl = pkgs.writeShellApplication {
    name = "couch-audio-output";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.hyprland
      pkgs.jq
      pkgs.pipewire
      pkgs.pulseaudio
      pkgs.systemd
      pkgs.wireplumber
    ];
    text = ''
      connector_audio_outputs=${lib.escapeShellArg (builtins.toJSON cfg.directDrmAudioOutputByConnector)}

      request_recovery() {
        systemctl --user --no-block start couch-audio-health-recovery.service \
          >/dev/null 2>&1 || true
      }

      load_graph() {
        if ! graph="$(timeout --kill-after=1 4 pw-dump)"; then
          echo "audio graph is unresponsive; requested recovery" >&2
          request_recovery
          return 1
        fi
      }
      load_graph

      get_sinks() {
        jq -c '
          [
            .[]
            | select(
                .type == "PipeWire:Interface:Node"
                and (.info.props["media.class"] // "") == "Audio/Sink"
              )
            | {
                id,
                description: (.info.props["node.description"] // .info.props["node.nick"] // .info.props["node.name"]),
                priority: (.info.props["priority.session"] // 0),
                api: (.info.props["device.api"] // ""),
                name: (.info.props["node.name"] // "")
              }
          ]
          | sort_by([-.priority, .description])
        ' <<<"$graph"
      }

      sinks="$(get_sinks)"
      if [ "$(jq 'length' <<<"$sinks")" -eq 0 ]; then
        echo "no audio outputs are available" >&2
        exit 1
      fi

      current_id="$(
        timeout --kill-after=1 4 wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null \
          | sed -n 's/^id \([0-9][0-9]*\),.*/\1/p' \
          | head -n1 \
          || true
      )"
      configured_name="$(
        jq -r '
          [
            .[]
            | select(
                .type == "PipeWire:Interface:Metadata"
                and (.props["metadata.name"] // "") == "default"
              )
            | .metadata[]?
            | select(.key == "default.configured.audio.sink")
            | .value.name // ""
          ][0] // ""
        ' <<<"$graph"
      )"

      set_default() {
        target_id="$1"
        target_name="$(
          jq -r --argjson id "$target_id" \
            '.[] | select(.id == $id) | .name' <<<"$sinks"
        )"
        if [ -z "$target_name" ]; then
          echo "selected audio output is no longer available" >&2
          return 1
        fi
        if ! timeout --kill-after=1 4 wpctl set-default "$target_id"; then
          echo "failed to select audio output; requested recovery" >&2
          request_recovery
          return 1
        fi

        # PipeWire-Pulse clients can keep their existing stream attached to a
        # disappearing Bluetooth or HDMI route even after WirePlumber changes
        # the default. Move each live stream in place so Moonlight keeps its
        # connection and server-side session while the output changes.
        if ! sink_inputs="$(timeout --kill-after=1 4 pactl list short sink-inputs)"; then
          echo "audio streams are unresponsive; requested recovery" >&2
          request_recovery
          return 1
        fi
        while read -r input_id _; do
          if [ -n "$input_id" ]; then
            timeout --kill-after=1 4 \
              pactl move-sink-input "$input_id" "$target_name" \
              >/dev/null 2>&1 || true
          fi
        done <<<"$sink_inputs"

        # SDL can retain the timing state of the previous HDMI sink after a
        # successful PipeWire-Pulse move into a Bluetooth latency domain. Ask
        # patched Moonlight clients to recreate only their audio renderer; the
        # video connection and remote application session remain untouched.
        audio_reopen_marker="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/moonlight-audio-reopen"
        printf '%s\n' "$(date +%s%N)" > "$audio_reopen_marker"
      }

      layout_target() {
        case "$1" in
          all | dual-tvs | living-bedroom) printf '%s\n' "Both TVs" ;;
          living | living-aux | primary-aux | solo-primary) printf '%s\n' "Primary TV" ;;
          bedroom | bedroom-aux | secondary-aux | solo-secondary) printf '%s\n' "Secondary TV" ;;
          aux | solo-aux | solo-tertiary) printf '%s\n' "Auxiliary display" ;;
          *) printf '%s\n' "" ;;
        esac
      }

      single_connector_target_id() {
        if [ "$(jq 'length' <<<"$connector_audio_outputs")" -eq 0 ]; then
          return
        fi

        if [ -z "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
          for socket in \
            "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/hypr/*/.socket.sock; do
            [ -S "$socket" ] || continue
            HYPRLAND_INSTANCE_SIGNATURE="''${socket%/.socket.sock}"
            HYPRLAND_INSTANCE_SIGNATURE="''${HYPRLAND_INSTANCE_SIGNATURE##*/}"
            export HYPRLAND_INSTANCE_SIGNATURE
            break
          done
        fi
        if [ -z "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
          return
        fi
        if ! monitors="$(
          timeout --kill-after=1 4 hyprctl -j monitors all 2>/dev/null
        )"; then
          return
        fi
        connector="$(
          jq -r '
            [
              .[]
              | select(
                  .disabled == false
                  and (.name | test("^(eDP|LVDS)-") | not)
                )
              | .name
            ]
            | if length == 1 then .[0] else "" end
          ' <<<"$monitors"
        )"
        if [ -z "$connector" ]; then
          return
        fi

        connector_target="$(
          jq -r --arg connector "$connector" \
            '.[$connector] // ""' <<<"$connector_audio_outputs"
        )"
        if [ -z "$connector_target" ]; then
          return
        fi

        jq -r --arg target "$connector_target" '
          [
            .[]
            | select(.name == $target or .description == $target)
          ][0].id // ""
        ' <<<"$sinks"
      }

      select_layout_fallback() {
        layout="''${1:-}"
        if [ -z "$layout" ]; then
          layout="$(tr -d '[:space:]' < ${lib.escapeShellArg displayLayoutStateFile} 2>/dev/null || true)"
        fi
        # A semantic layout can fall back to the only physically connected TV.
        # Prefer that connector's known audio path so, for example, a bedroom
        # layout using DP-3 cannot retain the disconnected Secondary TV PCM.
        target_id="$(single_connector_target_id)"
        if [ -z "$target_id" ]; then
          target="$(layout_target "$layout")"
          target_id="$(
            jq -r --arg target "$target" \
              '[.[] | select(.description == $target)][0].id // ""' <<<"$sinks"
          )"
        fi
        if [ -z "$target_id" ]; then
          # Adaptive or unavailable-role fallback: select the highest-priority
          # non-Bluetooth sink rather than retaining a vanished endpoint.
          target_id="$(
            jq -r '
              [
                .[]
                | select(
                    .api != "bluez5"
                    and (.name | startswith("bluez_") | not)
                  )
              ][0].id // ""
            ' <<<"$sinks"
          )"
        fi
        if [ -z "$target_id" ]; then
          echo "no local audio fallback is available" >&2
          return 1
        fi
        set_default "$target_id"
      }

      follow_layout() {
        requested_layout="''${1:-}"
        persisted_layout="$(
          tr -d '[:space:]' < ${lib.escapeShellArg displayLayoutStateFile} 2>/dev/null || true
        )"
        if [ -z "$requested_layout" ]; then
          requested_layout="$persisted_layout"
        fi

        current_description="$(
          jq -r --argjson current "''${current_id:--1}" \
            '.[] | select(.id == $current) | .description' <<<"$sinks"
        )"
        previous_layout_target="$(layout_target "$persisted_layout")"

        # Follow the display only while audio still matches the previous
        # layout's default. Any other live sink is an explicit user override
        # and remains selected across display-state changes.
        if [ -n "$current_description" ] \
          && [ -n "$previous_layout_target" ] \
          && [ "$current_description" != "$previous_layout_target" ]; then
          return
        fi

        select_layout_fallback "$requested_layout"
      }

      reconcile_default() {
        if [ -z "$configured_name" ]; then
          return
        fi
        if jq -e --arg name "$configured_name" \
          'any(.[]; .name == $name)' <<<"$sinks" >/dev/null; then
          return
        fi
        select_layout_fallback
      }

      case "''${1:-cycle}" in
        initialize)
          for ((attempt = 0; attempt < 20; attempt++)); do
            if [ "$(jq '[.[] | select(.name | test("playback[.][0387][.]0$"))] | length' <<<"$sinks")" -ge 4 ]; then
              break
            fi
            sleep 0.25
            load_graph
            sinks="$(get_sinks)"
          done
          while IFS= read -r sink_id; do
            wpctl set-volume "$sink_id" ${lib.escapeShellArg "${toString cfg.audioOutputStartupVolumePercent}%"}
          done < <(
            jq -r '.[] | select(.name | test("playback[.][0387][.]0$")) | .id' \
              <<<"$sinks"
          )
          follow_layout
          exit 0
          ;;
        follow-layout)
          follow_layout
          exit 0
          ;;
        select-name)
          if [ "$#" -ne 2 ]; then
            echo "usage: couch-audio-output select-name NODE_NAME" >&2
            exit 2
          fi
          next_id="$(
            jq -r --arg name "$2" \
              '[.[] | select(.name == $name)][0].id // ""' <<<"$sinks"
          )"
          if [ -z "$next_id" ]; then
            echo "requested audio output is no longer available" >&2
            exit 1
          fi
          set_default "$next_id"
          exit 0
          ;;
        reconcile)
          reconcile_default
          exit 0
          ;;
        prepare-layout)
          follow_layout "''${2:-}"
          # WirePlumber follows the new default target. Give it time to relink
          # live streams while the old HDMI sink still exists; otherwise SDL
          # loses its playback node when the display is parked and Moonlight
          # cannot recover that audio stream without reconnecting.
          sleep 1
          exit 0
          ;;
        status)
          jq -r --argjson current "''${current_id:--1}" \
            '.[] | select(.id == $current) | .description' <<<"$sinks"
          exit 0
          ;;
        cycle)
          next_id="$(
            jq -r --argjson current "''${current_id:--1}" '
              (map(.id) | index($current)) as $index
              | if $index == null then .[0].id
                else .[(($index + 1) % length)].id
                end
            ' <<<"$sinks"
          )"
          ;;
        *)
          echo "usage: couch-audio-output {initialize|follow-layout|select-name NODE_NAME|reconcile|prepare-layout LAYOUT|cycle|status}" >&2
          exit 2
          ;;
      esac

      description="$(
        jq -r --argjson id "$next_id" '.[] | select(.id == $id) | .description' \
          <<<"$sinks"
      )"
      set_default "$next_id"
      hyprctl notify 1 3000 'rgb(a6e3a1)' "Audio output: $description" \
        >/dev/null 2>&1 || true
      printf '%s\n' "$description"
    '';
  };

  audioHealthRecovery = pkgs.writeShellApplication {
    name = "couch-audio-health-recovery";
    runtimeInputs = [
      audioOutputControl
      pkgs.coreutils
      pkgs.systemd
      pkgs.wireplumber
    ];
    text = ''
      case "$(tr -d '[:space:]' < ${lib.escapeShellArg modeStateFile} 2>/dev/null || true)" in
        direct-*)
          # Direct DRM owns its own local-client lifecycle and audio route.
          exit 0
          ;;
      esac

      if ! systemctl --user --quiet is-active pipewire.service; then
        exit 0
      fi

      probe_audio() {
        timeout --kill-after=1 4 wpctl status >/dev/null 2>&1
      }

      reconcile_audio() {
        timeout --kill-after=1 5 couch-audio-output reconcile >/dev/null 2>&1
      }

      if probe_audio && reconcile_audio; then
        exit 0
      fi
      sleep 2
      if probe_audio && reconcile_audio; then
        exit 0
      fi

      # A failed Bluetooth/HDMI route can wedge WirePlumber while PipeWire and
      # its client streams are still healthy. Restarting only the session
      # manager preserves those streams and lets it rebuild their links.
      systemctl --user restart wireplumber.service
      for _ in 1 2; do
        sleep 1
        if probe_audio && reconcile_audio; then
          exit 0
        fi
      done

      # SDL clients such as Moonlight do not recreate their playback stream
      # after the PipeWire server disappears. Record the active local clients,
      # disconnect them inside their server-side grace window, rebuild audio,
      # select the persisted layout's sink, and immediately reconnect them.
      active_moonlight_units=()
      for moonlight_unit in \
        couch-moonlight-stream.service \
        couch-moonlight-browser-stream.service \
        couch-moonlight-browser-selector.service; do
        if systemctl --user --quiet is-active "$moonlight_unit"; then
          active_moonlight_units+=("$moonlight_unit")
        fi
      done

      dms_was_active=false
      if systemctl --user --quiet is-active couch-merged-dms.service; then
        dms_was_active=true
      fi

      sessions_stopped=false
      restore_sessions() {
        if ! "$sessions_stopped"; then
          return
        fi
        if "$dms_was_active"; then
          systemctl --user start couch-merged-dms.service || true
        fi
        for moonlight_unit in "''${active_moonlight_units[@]}"; do
          systemctl --user start "$moonlight_unit" || true
        done
      }
      trap restore_sessions EXIT

      sessions_stopped=true
      if [ "''${#active_moonlight_units[@]}" -gt 0 ]; then
        systemctl --user stop "''${active_moonlight_units[@]}"
      fi
      if "$dms_was_active"; then
        systemctl --user stop couch-merged-dms.service
      fi

      systemctl --user restart \
        pipewire.service \
        pipewire-pulse.service \
        wireplumber.service

      graph_healthy=false
      for _ in 1 2 3 4 5 6 7 8; do
        sleep 1
        if probe_audio; then
          graph_healthy=true
          break
        fi
      done
      if ! "$graph_healthy"; then
        echo "audio graph remains unhealthy after a bounded rebuild" >&2
        exit 1
      fi
      if ! reconcile_audio; then
        echo "audio graph recovered but its persisted display route did not" >&2
        exit 1
      fi

      restore_sessions
      sessions_stopped=false
      trap - EXIT
    '';
  };

  audioLayoutSync = pkgs.writeShellApplication {
    name = "couch-audio-follow-layout";
    runtimeInputs = [
      pkgs.coreutils
      waitForStableOutputs
      audioOutputControl
    ];
    text = ''
      couch-wait-for-stable-outputs
      sleep 2

      if timeout --kill-after=1 8 couch-audio-output follow-layout; then
        exit 0
      fi

      ${lib.optionalString cfg.enableAudioHealthRecovery ''
        ${lib.getExe audioHealthRecovery}
        sleep 2
        timeout --kill-after=1 8 couch-audio-output follow-layout
      ''}
    '';
  };
in {
  inherit audioOutputControl audioHealthRecovery audioLayoutSync;
}
