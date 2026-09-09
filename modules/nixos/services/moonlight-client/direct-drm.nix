{
  browserSelectorEndpointSetup,
  cfg,
  directDrmActiveKmsConfigFile,
  directDrmBrowserMoonlightInvocation,
  directDrmBrowserSelectorMoonlightInvocation,
  directDrmKeyboardLayoutFile,
  directDrmKmsConfigFile,
  directDrmMoonlightInvocation,
  directDrmReturnModeFile,
  lib,
  modeStateFile,
  moonlightEndpointSetup,
  persistentDirectDrmBrowserDefault,
  pkgs,
  qtConnectorName,
  streamReadinessHosts,
}: let
  directDrmOutputSnapshot = pkgs.writeShellApplication {
    name = "moonlight-direct-drm-output-snapshot";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
    ];
    text = ''
      runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
      if [ -z "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
        for socket_path in "$runtime_dir"/hypr/*/.socket.sock; do
          if [ -S "$socket_path" ]; then
            candidate_signature="$(basename "$(dirname "$socket_path")")"
            if HYPRLAND_INSTANCE_SIGNATURE="$candidate_signature" \
              XDG_RUNTIME_DIR="$runtime_dir" \
              hyprctl -j monitors >/dev/null 2>&1; then
              export HYPRLAND_INSTANCE_SIGNATURE="$candidate_signature"
              break
            fi
          fi
        done
      fi
      export XDG_RUNTIME_DIR="$runtime_dir"

      monitors="$(hyprctl -j monitors 2>/dev/null || true)"
      if ! jq -e 'type == "array"' <<<"$monitors" >/dev/null 2>&1; then
        echo "Could not query the active Hyprland output" >&2
        exit 1
      fi
      monitor="$(
        jq -c '
          ([.[] | select(.focused == true and .dpmsStatus == true)][0]
            // [.[] | select(.dpmsStatus == true)][0]
            // empty)
        ' <<<"$monitors"
      )"
      if [ -z "$monitor" ] || [ "$monitor" = null ]; then
        echo "No powered Hyprland output is available for direct DRM" >&2
        exit 1
      fi

      output="$(jq -r '.name' <<<"$monitor")"
      width="$(jq -r '.width' <<<"$monitor")"
      height="$(jq -r '.height' <<<"$monitor")"
      case "$width:$height" in
        *[!0-9:]* | :* | *:) echo "Invalid direct DRM output dimensions" >&2; exit 1 ;;
      esac

      connector_path=""
      for candidate in /sys/class/drm/card*-"$output"; do
        if [ -d "$candidate" ]; then
          connector_path="$candidate"
          break
        fi
      done
      if [ -z "$connector_path" ]; then
        echo "Could not map Hyprland output $output to a DRM connector" >&2
        exit 1
      fi

      connector_node="$(basename "$connector_path")"
      card_name="''${connector_node%%-*}"
      device="/dev/dri/$card_name"
      if [ ! -c "$device" ]; then
        echo "Direct DRM device $device is unavailable" >&2
        exit 1
      fi

      outputs='[]'
      for status_path in /sys/class/drm/"$card_name"-*/status; do
        [ -f "$status_path" ] || continue
        if [ "$(tr -d '[:space:]' < "$status_path")" != connected ]; then
          continue
        fi
        connector="$(basename "''${status_path%/status}")"
        connector="''${connector#"$card_name"-}"
        qt_connector="''${connector//-/}"
        case "$qt_connector" in
          HDMIA*) qt_connector="HDMI''${qt_connector#HDMIA}" ;;
          HDMIB*) qt_connector="HDMI''${qt_connector#HDMIB}" ;;
        esac
        if [ "$connector" = "$output" ]; then
          outputs="$(
            jq \
              --arg name "$qt_connector" \
              --arg mode "''${width}x''${height}" \
              '. + [{
                name: $name,
                mode: $mode,
                primary: true,
                virtualIndex: 0
              }]' \
              <<<"$outputs"
          )"
        else
          outputs="$(
            jq \
              --arg name "$qt_connector" \
              '. + [{name: $name, mode: "off"}]' \
              <<<"$outputs"
          )"
        fi
      done

      if ! jq -e 'any(.[]; .primary == true)' <<<"$outputs" >/dev/null; then
        echo "Selected direct DRM output disappeared during snapshot" >&2
        exit 1
      fi

      temporary="$(mktemp ${lib.escapeShellArg "${directDrmKmsConfigFile}.XXXXXX"})"
      trap 'rm -f "$temporary"' EXIT
      jq -n \
        --arg device "$device" \
        --argjson outputs "$outputs" \
        '{device: $device, outputs: $outputs}' \
        > "$temporary"
      chmod 0644 "$temporary"
      mv "$temporary" ${lib.escapeShellArg directDrmKmsConfigFile}
      trap - EXIT
      printf 'Direct DRM output: %s on %s at %sx%s\n' \
        "$output" "$device" "$width" "$height"
    '';
  };

  directDrmAudioOutputSetup = pkgs.writeShellApplication {
    name = "moonlight-direct-drm-audio-output";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.pipewire
      pkgs.wireplumber
    ];
    text = ''
      output="$(
        jq -r \
          '[.outputs[] | select(.primary == true)][0].name // empty' \
          ${lib.escapeShellArg directDrmActiveKmsConfigFile} \
          2>/dev/null \
          || true
      )"
      case "$output" in
        ${lib.concatStringsSep "\n        " (
        lib.mapAttrsToList (
          connector: description: "${
            lib.escapeShellArg (qtConnectorName connector)
          }) target=${lib.escapeShellArg description} ;;"
        )
        cfg.directDrmAudioOutputByConnector
      )}
        *) exit 0 ;;
      esac

      for ((attempt = 0; attempt < 20; attempt++)); do
        target_id="$(
          pw-dump 2>/dev/null \
            | jq -r --arg target "$target" '
                [
                  .[]
                  | select(
                      .type == "PipeWire:Interface:Node"
                      and (.info.props["media.class"] // "") == "Audio/Sink"
                      and (
                        (.info.props["node.description"] // "") == $target
                        or (.info.props["node.nick"] // "") == $target
                        or (.info.props["node.name"] // "") == $target
                      )
                    )
                ][0].id // empty
              ' \
            || true
        )"
        if [ -n "$target_id" ]; then
          wpctl set-default "$target_id"
          wpctl set-volume "$target_id" ${lib.escapeShellArg "${toString cfg.audioOutputStartupVolumePercent}%"}
          printf 'Direct DRM audio output: %s\n' "$target"
          exit 0
        fi
        sleep 0.25
      done

      echo "Direct DRM audio output is unavailable: $target" >&2
      exit 1
    '';
  };

  directDrmStreamHostPrepare = pkgs.writeShellApplication {
    name = "moonlight-direct-drm-stream-host-prepare";
    runtimeInputs = [pkgs.netcat-openbsd];
    text = ''
      stream_hosts=(${lib.concatMapStringsSep " " lib.escapeShellArg streamReadinessHosts})

      find_ready_host() {
        local host
        for host in "''${stream_hosts[@]}"; do
          if nc -z -w 1 "$host" ${toString cfg.streamReadinessPort} \
            >/dev/null 2>&1; then
            printf '%s\n' "$host"
            return 0
          fi
        done
        return 1
      }

      ${lib.optionalString (cfg.streamHostStartCommand != null || streamReadinessHosts != []) ''
        ready_host="$(find_ready_host || true)"
      ''}

      ${lib.optionalString (cfg.streamHostStartCommand != null) ''
        if [ -z "$ready_host" ]; then
          start_target=""
          for host in "''${stream_hosts[@]}"; do
            if nc -z -w 1 "$host" ${toString cfg.streamHostControlPort} \
              >/dev/null 2>&1; then
              start_target="$host"
              break
            fi
          done
          if [ -z "$start_target" ] && [ "''${#stream_hosts[@]}" -gt 0 ]; then
            start_target="''${stream_hosts[0]}"
          fi
          export COUCH_STREAM_START_TARGET="$start_target"
          ${cfg.streamHostStartCommand}
        fi
      ''}

      ${lib.optionalString (streamReadinessHosts != []) ''
        ready_host=""
        for ((attempt = 0; attempt < ${toString cfg.streamStartupTimeout}; attempt++)); do
          ready_host="$(find_ready_host || true)"
          if [ -n "$ready_host" ]; then
            exit 0
          fi
          sleep 1
        done
        echo "stream host did not become ready" >&2
        exit 1
      ''}
    '';
  };
  mkDirectDrmSession = {
    name,
    mode,
    endpointSetup,
    invocation,
    application ? null,
    prepareCommand ? null,
    retryOnExit ? false,
  }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.systemd
      ];
      text = ''
        active_mode=${lib.escapeShellArg mode}
        persist_mode() {
          mode_tmp="$(mktemp ${lib.escapeShellArg "${modeStateFile}.XXXXXX"})"
          printf '%s\n' "$1" > "$mode_tmp"
          chmod 0644 "$mode_tmp"
          mv -f "$mode_tmp" ${lib.escapeShellArg modeStateFile}
        }
        return_mode="$(
          tr -d '[:space:]' \
            < ${lib.escapeShellArg directDrmReturnModeFile} \
            2>/dev/null \
            || true
        )"
        case "$return_mode" in
          couch${
          lib.optionalString (cfg.desktopSessionCommand != null) " | desktop"
        }${lib.optionalString cfg.enableMergedProfile " | merged"}${
          lib.optionalString (cfg.defaultSessionMode == mode) " | ${mode}"
        }) ;;
          *) return_mode=${lib.escapeShellArg cfg.defaultSessionMode} ;;
        esac

        return_to_session() {
          status="''${1:-0}"
          trap - EXIT HUP INT TERM
          current_mode="$(
            tr -d '[:space:]' \
              < ${lib.escapeShellArg modeStateFile} \
              2>/dev/null \
              || true
          )"
          current_mode="''${current_mode%%:*}"
          if [ -z "$current_mode" ]; then
            current_mode=${lib.escapeShellArg cfg.defaultSessionMode}
          fi
          # An operator may force a direct session back to couch over SSH.
          # Preserve that explicit request instead of racing it with the
          # exiting DRM wrapper's normal return mode.
          if [ "$current_mode" = "$active_mode" ] \
              && [ "$return_mode" != "$current_mode" ]; then
            persist_mode "$return_mode"
            # Keep greetd's initial session alive long enough for the path unit
            # to restart it. Otherwise greetd can race ahead to its greeter,
            # which then needs the bounded stop timeout before recovery.
            sleep 2
          fi
          exit "$status"
        }
        trap 'return_to_session 0' HUP INT TERM
        trap 'return_to_session $?' EXIT

        # These processes depend on Hyprland/XWayland and cannot operate while
        # EGLFS owns the display. Hyprland's exec-once hooks restore them when
        # the normal couch session returns.
        systemctl --user stop \
          couch-moonlight-stream.service \
          couch-moonlight-browser-stream.service \
          couch-moonlight-browser-selector.service \
          couch-protected-browser.service \
          couch-dms.service \
          couch-merged-dms.service \
          kdeconnect.service \
          waynergy.service \
          xdg-desktop-portal-gtk.service \
          >/dev/null 2>&1 || true
        # The compositor may disappear before its clients process the stop
        # request, causing an otherwise expected broken Wayland connection to
        # leave a failed-unit marker behind for the whole DRM session.
        systemctl --user reset-failed \
          couch-moonlight-stream.service \
          couch-moonlight-browser-stream.service \
          couch-moonlight-browser-selector.service \
          couch-protected-browser.service \
          couch-dms.service \
          couch-merged-dms.service \
          kdeconnect.service \
          waynergy.service \
          xdg-desktop-portal-gtk.service \
          >/dev/null 2>&1 || true

        ${lib.optionalString cfg.enableKdeConnect ''
          # Direct DRM has no compositor-owned X display. The supervised KDE
          # Connect launcher supplies an isolated Xvfb display while its
          # preload shim forwards phone input into the direct uinput bridge.
          systemctl --user restart kdeconnect.service >/dev/null 2>&1 || true
        ''}

        ${lib.optionalString (prepareCommand != null) "${prepareCommand}\n"}
        run_moonlight() {
          if ${lib.getExe endpointSetup}; then
            :
          else
            status=$?
            return "$status"
          fi
          ${lib.optionalString (
          cfg.directDrmAudioOutputByConnector != {}
        ) "${lib.getExe directDrmAudioOutputSetup}"}
          ${
          if cfg.directDrmLogToJournal
          then ''
            log_dir="$(mktemp -d "''${XDG_RUNTIME_DIR:-/tmp}/moonlight-direct-drm.XXXXXX")"
            log_fifo="$log_dir/output"
            pid_file="$log_dir/pid"
            mkfifo -m 600 "$log_fifo"
            (
              while IFS= read -r line || [ -n "$line" ]; do
                printf '%s\n' "$line" > /dev/tty1
                printf '%s\n' "$line"
                case "$line" in
                  *"Connection terminated:"*)
                    if read -r failed_pid < "$pid_file"; then
                      kill -TERM "$failed_pid" 2>/dev/null || true
                    fi
                    ;;
                esac
              done < "$log_fifo"
            ) | ${pkgs.systemd}/bin/systemd-cat --identifier=moonlight-direct-drm &
            logger_pid=$!
            ${invocation} \
              > "$log_fifo" 2>&1 &
          ''
          else "${invocation} &"
        }
          moonlight_pid=$!
          ${lib.optionalString cfg.directDrmLogToJournal ''
          printf '%s\n' "$moonlight_pid" > "$pid_file"
        ''}

          ${lib.optionalString (cfg.browserStreamLayoutCommand != null) ''
          (
            COUCH_KEYBOARD_LAYOUT="$(
              tr -d '[:space:]' \
                < ${lib.escapeShellArg directDrmKeyboardLayoutFile} \
                2>/dev/null \
                || true
            )"
            if [ -z "$COUCH_KEYBOARD_LAYOUT" ]; then
              configured_layouts=${lib.escapeShellArg cfg.keyboardLayouts}
              COUCH_KEYBOARD_LAYOUT="''${configured_layouts%%,*}"
            fi
            export COUCH_KEYBOARD_LAYOUT
            export COUCH_PRESENTATION_SCALE=${toString cfg.browserPresentationScale}
            export COUCH_STREAM_APPLICATION=${
            lib.escapeShellArg (
              if application == null
              then ""
              else application
            )
          }
            ${cfg.browserStreamLayoutCommand}
          ) &
        ''}

          if wait "$moonlight_pid"; then
            status=0
          else
            status=$?
          fi
          ${lib.optionalString cfg.directDrmLogToJournal ''
          wait "$logger_pid" 2>/dev/null || true
          rm -f "$log_fifo" "$pid_file"
          rmdir "$log_dir"
        ''}
        }

        ${
          if retryOnExit
          then ''
            # Persistent direct-display appliances should recover after a
            # coordinator or network outage without returning to the greeter.
            # An explicit mode change is still authoritative: its control path
            # updates the mode file before terminating Moonlight.
            while true; do
              if run_moonlight; then
                :
              else
                status=$?
              fi
              current_mode="$(
                tr -d '[:space:]' \
                  < ${lib.escapeShellArg modeStateFile} \
                  2>/dev/null \
                || true
              )"
              current_mode="''${current_mode%%:*}"
              if [ -z "$current_mode" ]; then
                current_mode=${lib.escapeShellArg cfg.defaultSessionMode}
              fi
              if [ "$current_mode" != "$active_mode" ]; then
                return_to_session "$status"
              fi
              sleep 2
            done
          ''
          else ''
            run_moonlight
            return_to_session "$status"
          ''
        }
      '';
    };
  directDrmBrowserSession = mkDirectDrmSession {
    name = "moonlight-direct-drm-browser-session";
    mode = "direct-browser";
    endpointSetup = moonlightEndpointSetup;
    invocation = directDrmBrowserMoonlightInvocation;
    application = cfg.browserStreamApplication;
    prepareCommand = cfg.browserStreamPrepareCommand;
    retryOnExit = persistentDirectDrmBrowserDefault;
  };
  directDrmBrowserSelectorSession = mkDirectDrmSession {
    name = "moonlight-direct-drm-browser-selector-session";
    mode = "direct-private";
    endpointSetup = browserSelectorEndpointSetup;
    invocation = directDrmBrowserSelectorMoonlightInvocation;
    application = cfg.browserStreamSelectorApplication;
  };
  directDrmStreamSession = mkDirectDrmSession {
    name = "moonlight-direct-drm-stream-session";
    mode = "direct-stream";
    endpointSetup = moonlightEndpointSetup;
    invocation = directDrmMoonlightInvocation;
    prepareCommand = lib.getExe directDrmStreamHostPrepare;
  };
in {
  inherit
    directDrmBrowserSelectorSession
    directDrmBrowserSession
    directDrmOutputSnapshot
    directDrmStreamSession
    ;
}
