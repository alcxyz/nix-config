# nix-config/modules/nixos/services/moonlight-client/default.nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.moonlight-client;

  modeStateDirectory = "/var/lib/moonlight-client";
  modeStateFile = "${modeStateDirectory}/session-mode";
  runtimeStateDirectory = "/run/moonlight-client";
  dynamicMonitorConfigFile = "${runtimeStateDirectory}/monitors.conf";
  mirrorStateFile = "${modeStateDirectory}/mirror-enabled";
  displayLayoutStateFile = "${modeStateDirectory}/display-layout";
  mergedDmsConfigDirectory = "${runtimeStateDirectory}/dms-merged";
  effectiveMergedDmsSettings = lib.recursiveUpdate (lib.optionalAttrs
    (cfg.sessionSplashCommand != null)
    {
      customPowerActionReboot = "${lib.getExe sessionPowerAction} reboot";
      customPowerActionPowerOff = "${lib.getExe sessionPowerAction} poweroff";
    }
  ) cfg.mergedDmsSettings;
  mergedDmsSettingsFile = pkgs.writeText "dms-merged-settings.json" (
    builtins.toJSON effectiveMergedDmsSettings
  );
  mergedDmsCheatsheetFile = pkgs.writeText "xps-media-center.json" (
    builtins.toJSON {
      title = "XPS media center";
      provider = "xps-media-center";
      binds = {
        Controller = [
          {
            key = "Home A";
            desc = "Steam/Moonlight";
          }
          {
            key = "Home X";
            desc = "Remote Helium";
          }
          {
            key = "L3 R3";
            desc = "Back to Helium";
          }
          {
            key = "Minus Plus";
            desc = "Mirror toggle";
          }
          {
            key = "Minus X";
            desc = "Next layout";
          }
          {
            key = "Minus Y";
            desc = "Next audio";
          }
          {
            key = "Minus B";
            desc = "Show guide";
          }
        ];
        "Apps · ◆ = Super" = [
          {
            key = "◆ M";
            desc = "Steam/Moonlight";
          }
          {
            key = "◆ R";
            desc = "Remote Helium";
          }
          {
            key = "◆ B";
            desc = "Back to Helium";
          }
          {
            key = "◆ ⇧ M";
            desc = "Mirror toggle";
          }
          {
            key = "◆ ⇧ D";
            desc = "Next layout";
          }
          {
            key = "◆ ⇧ A";
            desc = "Next audio";
          }
          {
            key = "◆ V";
            desc = "New Helium";
          }
          {
            key = "Alt Enter";
            desc = "Terminal";
          }
          {
            key = "◆ Space";
            desc = "DMS search";
          }
        ];
        "Windows & audio" = [
          {
            key = "◆ Enter";
            desc = "Fullscreen";
          }
          {
            key = "◆ S";
            desc = "Floating";
          }
          {
            key = "◆ W";
            desc = "Close";
          }
          {
            key = "◆ 1–9";
            desc = "Active workspace";
          }
          {
            key = "◆ J/K";
            desc = "Previous / next";
          }
          {
            key = "◆ ⇧ 1–0";
            desc = "Move window";
          }
          {
            key = "F8 F9 F10";
            desc = "Volume controls";
          }
          {
            key = "Alt Shift";
            desc = "NO / US layout";
          }
          {
            key = "◆ H";
            desc = "Show guide";
          }
        ];
      };
    }
  );
  directStreamEnabled = cfg.streamHost != null && cfg.streamApplication != null;
  browserStreamEnabled = cfg.browserStreamHost != null && cfg.browserStreamApplication != null;
  browserSelectorEnabled = browserStreamEnabled && cfg.browserStreamSelectorApplication != null;
  dynamicExternalLayoutEnabled = cfg.autoLayoutExternalOutputs || cfg.autoMirrorExternalOutputs;
  defaultOutputMode =
    if dynamicExternalLayoutEnabled then lib.last cfg.autoLayoutSecondaryModes else cfg.outputMode;
  mirrorOutputMode = if cfg.mirrorOutputMode == null then cfg.outputMode else cfg.mirrorOutputMode;
  autoMirrorOutputMode = if cfg.mirrorOutputMode == null then "" else cfg.mirrorOutputMode;
  autoMirrorSecondaryPosition =
    if cfg.autoMirrorSecondaryPosition == null then
      cfg.autoLayoutSecondaryPosition
    else
      cfg.autoMirrorSecondaryPosition;
  autoMirrorTertiaryPosition =
    if cfg.autoMirrorTertiaryPosition == null then
      cfg.autoLayoutTertiaryPosition
    else
      cfg.autoMirrorTertiaryPosition;
  mirrorSourceOutputs = lib.unique (lib.attrValues cfg.mirrorOutputs);
  mkMoonlightInvocation =
    extraArguments: host: application:
    lib.escapeShellArgs (
      [
        "${pkgs.coreutils}/bin/env"
        "QT_QPA_PLATFORM=${cfg.moonlightPlatform}"
        (lib.getExe cfg.package)
        "stream"
      ]
      ++ cfg.streamArguments
      ++ extraArguments
      ++ [
        host
        application
      ]
    );
  moonlightInvocation =
    if directStreamEnabled then
      mkMoonlightInvocation [ ] cfg.streamHost cfg.streamApplication
    else
      lib.escapeShellArgs [
        "${pkgs.coreutils}/bin/env"
        "QT_QPA_PLATFORM=${cfg.moonlightPlatform}"
        (lib.getExe cfg.package)
      ];
  browserMoonlightInvocation = lib.optionalString browserStreamEnabled (
    mkMoonlightInvocation cfg.browserStreamArguments cfg.browserStreamHost cfg.browserStreamApplication
  );
  browserSelectorMoonlightInvocation = lib.optionalString browserSelectorEnabled (
    mkMoonlightInvocation cfg.browserStreamArguments cfg.browserStreamHost
      cfg.browserStreamSelectorApplication
  );
  superviseMoonlightWindow = ''
    seen_window=0
    startup_window_checks=0
    missing_window_checks=0

    terminate_moonlight() {
      kill "$moonlight_pid" >/dev/null 2>&1 || true
      sleep 1
      kill -KILL "$moonlight_pid" >/dev/null 2>&1 || true
    }

    while kill -0 "$moonlight_pid" >/dev/null 2>&1; do
      if hyprctl -j clients 2>/dev/null \
        | jq -e 'any(.[]; .class == "com.moonlight_stream.Moonlight" and .mapped)' \
          >/dev/null 2>&1; then
        seen_window=1
        startup_window_checks=0
        missing_window_checks=0
      elif [ "$seen_window" -eq 1 ]; then
        missing_window_checks=$((missing_window_checks + 1))
        if [ "$missing_window_checks" -ge 5 ]; then
          terminate_moonlight
          break
        fi
      else
        startup_window_checks=$((startup_window_checks + 1))
        if [ "$startup_window_checks" -ge 30 ]; then
          terminate_moonlight
          break
        fi
      fi
      sleep 1
    done

    status=0
    wait "$moonlight_pid" || status=$?
  '';
  streamEndpointPolicyEnabled = cfg.streamLocalAddress != null && cfg.streamRemoteAddress != null;
  browserStreamEndpointPolicyEnabled =
    cfg.browserStreamLocalAddress != null && cfg.browserStreamRemoteAddress != null;
  browserStreamReadinessHosts =
    if browserStreamEndpointPolicyEnabled then
      [
        cfg.browserStreamLocalAddress
        cfg.browserStreamRemoteAddress
      ]
    else
      lib.optional browserStreamEnabled cfg.browserStreamHost;
  streamReadinessHosts =
    if streamEndpointPolicyEnabled then
      [
        cfg.streamLocalAddress
        cfg.streamRemoteAddress
      ]
    else
      lib.optional (cfg.streamReadinessHost != null) cfg.streamReadinessHost;
  reconcileMoonlightEndpoints = pkgs.writeShellApplication {
    name = "reconcile-moonlight-endpoints";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec python3 ${./reconcile-endpoints.py} "$@"
    '';
  };
  moonlightEndpointSetup = pkgs.writeShellApplication {
    name = "moonlight-endpoint-setup";
    text = ''
      config_file="$HOME/.config/Moonlight Game Streaming Project/Moonlight.conf"
      ${lib.optionalString streamEndpointPolicyEnabled ''
        ${lib.getExe reconcileMoonlightEndpoints} \
          "$config_file" \
          ${lib.escapeShellArg cfg.streamHost} \
          ${lib.escapeShellArg cfg.streamLocalAddress} \
          ${lib.escapeShellArg cfg.streamRemoteAddress}
      ''}
      ${lib.optionalString browserStreamEndpointPolicyEnabled ''
        ${lib.getExe reconcileMoonlightEndpoints} \
          "$config_file" \
          ${lib.escapeShellArg cfg.browserStreamHost} \
          ${lib.escapeShellArg cfg.browserStreamLocalAddress} \
          ${lib.escapeShellArg cfg.browserStreamRemoteAddress}
      ''}
    '';
  };

  displayModeSetup = pkgs.writeShellApplication {
    name = "moonlight-display-mode";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.jq
    ];
    text = ''
      target_spec=${lib.escapeShellArg cfg.outputMode}
      target_dimensions="''${target_spec%@*}"
      target_refresh="''${target_spec##*@}"
      target_width="''${target_dimensions%x*}"
      target_height="''${target_dimensions#*x}"
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

      ${lib.optionalString (cfg.fallbackOutputMode != null) ''
        if [ "$external_seen" -eq 1 ]; then
          hyprctl keyword monitor ${lib.escapeShellArg ", ${cfg.fallbackOutputMode}, auto, ${toString cfg.outputScale}"}
        fi
      ''}
    '';
  };

  hdmiAudioSetup = pkgs.writeShellApplication {
    name = "moonlight-hdmi-audio";
    runtimeInputs = [
      pkgs.gawk
      pkgs.pulseaudio
      pkgs.systemd
    ];
    text = ''
      systemctl --user start pipewire.service wireplumber.service pipewire-pulse.socket \
        >/dev/null 2>&1 || true

      for ((attempt = 0; attempt < 20; attempt++)); do
        while read -r card; do
          pactl set-card-profile "$card" output:hdmi-stereo >/dev/null 2>&1 || true
        done < <(pactl list short cards 2>/dev/null | awk '{ print $2 }')

        sink="$(pactl list short sinks 2>/dev/null | awk '$2 ~ /hdmi/ { print $2; exit }')"
        if [ -n "$sink" ]; then
          pactl set-default-sink "$sink"
          exit 0
        fi
        sleep 0.5
      done

      exit 1
    '';
  };

  moonlightSession = pkgs.writeShellApplication {
    name = "moonlight-session";
    runtimeInputs = [
      cfg.package
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
    ];
    text =
      if cfg.relaunchOnExit then
        ''
          ${lib.getExe moonlightEndpointSetup}
          ${lib.getExe displayModeSetup}
          ${lib.optionalString cfg.preferHdmiAudio "${lib.getExe hdmiAudioSetup} || true"}

          while true; do
            ${moonlightInvocation} &
            moonlight_pid=$!
            ${superviseMoonlightWindow}
            sleep 1
          done
        ''
      else
        ''
          ${lib.getExe moonlightEndpointSetup}
          ${lib.getExe displayModeSetup}
          ${lib.optionalString cfg.preferHdmiAudio "${lib.getExe hdmiAudioSetup} || true"}

          ${moonlightInvocation} &
          moonlight_pid=$!
          ${superviseMoonlightWindow}
          hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
          exit "$status"
        '';
  };

  couchBrowser = pkgs.writeShellApplication {
    name = "couch-browser";
    runtimeInputs = [ pkgs.hyprland ];
    text = ''
      hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
      exec ${lib.getExe cfg.browserPackage} \
        --class=CouchBrowser \
        --user-data-dir="$HOME/.local/share/${cfg.browserProfileDirectory}" \
        --ozone-platform=x11 \
        --password-store=basic \
        --force-device-scale-factor=${toString cfg.browserScaleFactor} \
        "$@"
    '';
  };

  couchBrowserNewWindow = pkgs.writeShellApplication {
    name = "couch-browser-new-window";
    text = ''
      exec ${lib.getExe couchBrowser} --new-window "$@"
    '';
  };

  couchBrowserStartup = pkgs.writeShellApplication {
    name = "couch-browser-startup";
    runtimeInputs = [
      pkgs.netcat-openbsd
      pkgs.systemd
    ];
    text = ''
      # Hyprland launches exec-once commands concurrently. Import the current
      # compositor environment here before systemd starts the supervised
      # Moonlight unit, so its hyprctl window health check cannot race the
      # session-wide environment import.
      systemctl --user import-environment \
        WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP \
        DBUS_SESSION_BUS_ADDRESS >/dev/null 2>&1 || true

      remote_hosts=(${lib.concatMapStringsSep " " lib.escapeShellArg browserStreamReadinessHosts})

      for ((attempt = 0; attempt < ${toString cfg.browserStartupTimeout}; attempt++)); do
        for host in "''${remote_hosts[@]}"; do
          if nc -z -w 1 "$host" ${toString cfg.streamReadinessPort} \
            >/dev/null 2>&1; then
            systemctl --user reset-failed couch-moonlight-browser-stream.service \
              >/dev/null 2>&1 || true
            if systemctl --user start couch-moonlight-browser-stream.service; then
              exit 0
            fi
          fi
        done
        sleep 1
      done

      exec ${lib.getExe couchBrowser}
    '';
  };

  couchTerminal = pkgs.writeShellApplication {
    name = "couch-terminal";
    runtimeInputs = [ pkgs.hyprland ];
    text = ''
      hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
      exec ${lib.getExe cfg.terminalPackage}
    '';
  };

  couchFallbackBrowser = lib.optionalAttrs (cfg.fallbackBrowserPackage != null) {
    package = pkgs.writeShellApplication {
      name = "couch-browser-fallback";
      runtimeInputs = [ pkgs.hyprland ];
      text = ''
        hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
        exec ${lib.getExe cfg.fallbackBrowserPackage} \
          --user-data-dir="$HOME/.local/share/${cfg.fallbackBrowserProfileDirectory}" \
          --ozone-platform=x11 \
          --password-store=basic \
          --force-device-scale-factor=${toString cfg.browserScaleFactor} \
          "$@"
      '';
    };
  };

  protectedBrowserPasswordPrompt = pkgs.writeShellApplication {
    name = "couch-protected-browser-password";
    runtimeInputs = [ pkgs.zenity ];
    text = ''
      export GDK_BACKEND=x11
      case "''${1:-unlock}" in
        create)
          prompt=${lib.escapeShellArg "Choose a password for the protected ${cfg.protectedBrowserName} profile"}
          ;;
        confirm)
          prompt=${lib.escapeShellArg "Confirm the password for the protected ${cfg.protectedBrowserName} profile"}
          ;;
        *)
          prompt=${lib.escapeShellArg "Enter the password for the protected ${cfg.protectedBrowserName} profile"}
          ;;
      esac
      exec zenity \
        --password \
        --title=${lib.escapeShellArg "Unlock ${cfg.protectedBrowserName}"} \
        --text="$prompt"
    '';
  };

  protectedBrowserSession = pkgs.writeShellApplication {
    name = "${cfg.protectedBrowserCommandName}-session";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gocryptfs
      pkgs.hyprland
      pkgs.jq
      pkgs.socat
      pkgs.util-linux
      pkgs.zenity
    ];
    text = ''
      # FUSE mounts on NixOS must use the privileged wrappers, not the
      # unwrapped fusermount binaries from a package dependency.
      export PATH="/run/wrappers/bin:$PATH"

      cipher_directory="$HOME/.local/share/${cfg.protectedBrowserEncryptedDirectory}"
      runtime_directory="''${XDG_RUNTIME_DIR:-/run/user/$UID}/${cfg.protectedBrowserRuntimeDirectory}"
      mountpoint="$runtime_directory/profile"
      mounted_here=false
      initial_password=""
      placement_pid=""
      launch_workspace="$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id // 2')"

      focus_launch_workspace() {
        hyprctl dispatch workspace "$launch_workspace" >/dev/null 2>&1 || true
      }

      place_protected_windows() {
        event_socket="''${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
        socat -u "UNIX-CONNECT:$event_socket" - 2>/dev/null |
          while IFS= read -r event; do
            case "$event" in
              openwindow\>\>*) ;;
              *) continue ;;
            esac

            window_data="''${event#openwindow>>}"
            IFS=, read -r address _workspace window_class window_title <<<"$window_data"
            if { [ "$window_class" = zenity ] \
                && [[ "$window_title" == *${lib.escapeShellArg cfg.protectedBrowserName}* ]]; } \
              || [ "$window_class" = ProtectedBrowser ]; then
              address="0x''${address#0x}"
              hyprctl dispatch movetoworkspacesilent \
                "$launch_workspace,address:$address" >/dev/null 2>&1 || true
              hyprctl dispatch focuswindow "address:$address" >/dev/null 2>&1 || true
              hyprctl dispatch centerwindow >/dev/null 2>&1 || true
            fi
          done
      }

      show_error() {
        GDK_BACKEND=x11 zenity \
          --error \
          --title=${lib.escapeShellArg cfg.protectedBrowserName} \
          --text="$1" >/dev/null 2>&1 || true
      }

      # shellcheck disable=SC2329 # Invoked by the trap below.
      cleanup() {
        if [ -n "$placement_pid" ]; then
          kill "$placement_pid" 2>/dev/null || true
          wait "$placement_pid" 2>/dev/null || true
        fi
        if [ "$mounted_here" = true ] && mountpoint -q "$mountpoint"; then
          if ! /run/wrappers/bin/fusermount3 -u "$mountpoint"; then
            show_error ${lib.escapeShellArg "${cfg.protectedBrowserName} has closed, but its encrypted profile is still mounted. Close any remaining browser processes and run this launcher again to finish locking it."}
          fi
        fi
      }
      trap cleanup EXIT
      trap 'exit 0' HUP INT TERM

      install -d -m 0700 "$cipher_directory" "$runtime_directory" "$mountpoint"
      exec 9>"$runtime_directory/launcher.lock"
      if ! flock -n 9; then
        show_error ${lib.escapeShellArg "The protected browser is already opening or running."}
        exit 1
      fi
      focus_launch_workspace
      # The event listener must not inherit the launcher lock. Otherwise a
      # failed password prompt can leave socat holding the lock after this
      # shell exits, permanently blocking every later attempt.
      place_protected_windows 9>&- &
      placement_pid=$!

      if [ ! -e "$cipher_directory/gocryptfs.conf" ]; then
        GDK_BACKEND=x11 zenity \
          --info \
          --title=${lib.escapeShellArg "Protect ${cfg.protectedBrowserName}"} \
          --text=${lib.escapeShellArg "Choose a password for the protected browser. You will be asked for it twice during this one-time setup. The profile can be recovered through browser sync if this password is lost."} \
          >/dev/null 2>&1 || true

        initial_password="$(${lib.getExe protectedBrowserPasswordPrompt} create)" || exit 1
        confirmation="$(${lib.getExe protectedBrowserPasswordPrompt} confirm)" || exit 1
        if [ -z "$initial_password" ] || [ "$initial_password" != "$confirmation" ]; then
          unset confirmation initial_password
          show_error ${lib.escapeShellArg "The passwords were empty or did not match. The protected profile was not initialized."}
          exit 1
        fi
        unset confirmation

        if ! printf '%s\n' "$initial_password" | gocryptfs \
          -q \
          -init \
          -passfile /dev/stdin \
          "$cipher_directory"; then
          unset initial_password
          show_error ${lib.escapeShellArg "The encrypted browser profile could not be initialized."}
          exit 1
        fi
      fi

      if ! mountpoint -q "$mountpoint"; then
        if [ -n "$initial_password" ]; then
          printf '%s\n' "$initial_password" | gocryptfs \
            -q \
            -passfile /dev/stdin \
            "$cipher_directory" \
            "$mountpoint" || mount_status=$?
        else
          gocryptfs \
            -q \
            -extpass ${lib.escapeShellArg (lib.getExe protectedBrowserPasswordPrompt)} \
            "$cipher_directory" \
            "$mountpoint" || mount_status=$?
        fi
        unset initial_password
        if [ "''${mount_status:-0}" -ne 0 ]; then
          show_error ${lib.escapeShellArg "The protected browser profile could not be unlocked or mounted. Check the password and try again; if it persists, inspect the mount service."}
          exit 1
        fi
        mounted_here=true
      fi

      ${lib.optionalString (cfg.protectedBrowserLegacyProfileDirectory != null) ''
        legacy_profile=${lib.escapeShellArg cfg.protectedBrowserLegacyProfileDirectory}
        if [ -e "$legacy_profile/Local State" ] \
          && [ -z "$(find "$mountpoint" -mindepth 1 -print -quit)" ]; then
          legacy_lock="$(readlink "$legacy_profile/SingletonLock" 2>/dev/null || true)"
          legacy_pid="''${legacy_lock##*-}"
          if [ -n "$legacy_lock" ] \
            && [ "$legacy_pid" != "$legacy_lock" ] \
            && kill -0 "$legacy_pid" 2>/dev/null; then
            show_error ${lib.escapeShellArg "Close the existing Brave window first. Its temporary profile is safe and will be migrated on the next protected launch."}
            exit 1
          fi

          cp -a --reflink=auto "$legacy_profile/." "$mountpoint/"
          rm -f \
            "$mountpoint/SingletonCookie" \
            "$mountpoint/SingletonLock" \
            "$mountpoint/SingletonSocket"
          touch "$mountpoint/.couch-profile-migrated"
        fi
      ''}

      flock -u 9
      exec 9>&-
      focus_launch_workspace

      status=0
      ${lib.getExe cfg.protectedBrowserPackage} \
        --class=ProtectedBrowser \
        --user-data-dir="$mountpoint" \
        --ozone-platform=x11 \
        --password-store=basic \
        --force-device-scale-factor=${toString cfg.browserScaleFactor} \
        --disable-background-mode \
        "$@" || status=$?
      exit "$status"
    '';
  };

  protectedBrowser = pkgs.writeShellApplication {
    name = cfg.protectedBrowserCommandName;
    runtimeInputs = [
      pkgs.hyprland
      pkgs.systemd
    ];
    text = ''
      unit=couch-protected-browser.service
      if systemctl --user --quiet is-active "$unit"; then
        hyprctl dispatch focuswindow 'class:^(ProtectedBrowser)$' >/dev/null 2>&1 || true
        exit 0
      fi

      systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
      exec systemctl --user start "$unit"
    '';
  };

  moonlightStreamStart = pkgs.writeShellApplication {
    name = "couch-moonlight-start";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.netcat-openbsd
    ];
    text = ''
      stream_hosts=(${lib.concatMapStringsSep " " lib.escapeShellArg streamReadinessHosts})

      show_status() {
        level="$1"
        message="$2"
        details="$3"
        dms="$HOME/.nix-profile/bin/dms"
        if [ -x "$dms" ]; then
          "$dms" ipc call toast "''${level}With" \
            "$message" "$details" "" "media-center" >/dev/null 2>&1 || true
        else
          hyprctl notify 1 5000 'rgb(89b4fa)' "$message — $details" \
            >/dev/null 2>&1 || true
        fi
      }

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

      ready_host="$(find_ready_host || true)"

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
          show_status info "Starting Steam" \
            "Starting the remote Steam host. A cold start can take up to ${toString cfg.streamStartupTimeout} seconds."
          ${cfg.streamHostStartCommand}
          show_status info "Steam container started" \
            "Waiting for the streaming service to become ready."
        fi
      ''}

      ${lib.optionalString (streamReadinessHosts != [ ]) ''
        ready_host=""
        for ((attempt = 0; attempt < ${toString cfg.streamStartupTimeout}; attempt++)); do
          ready_host="$(find_ready_host || true)"
          if [ -n "$ready_host" ]; then
            break
          fi
          sleep 1
        done

        if [ -z "$ready_host" ]; then
          show_status error "Steam did not start" \
            "The streaming service was not ready after ${toString cfg.streamStartupTimeout} seconds."
          echo "stream host did not become ready" >&2
          exit 1
        fi
      ''}

      show_status info "Steam is ready" "Connecting Moonlight now."
      exec ${lib.getExe moonlightSession}
    '';
  };

  mkMoonlightBrowserSession =
    name: invocation:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.hyprland
        pkgs.jq
      ];
      text = ''
        ${lib.getExe moonlightEndpointSetup}
        ${lib.getExe displayModeSetup}
        ${invocation} &
        moonlight_pid=$!
        ${superviseMoonlightWindow}
        hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
        exit "$status"
      '';
    };
  moonlightBrowserSession = mkMoonlightBrowserSession "moonlight-browser-session" browserMoonlightInvocation;
  moonlightBrowserSelectorSession = mkMoonlightBrowserSession "moonlight-browser-selector-session" browserSelectorMoonlightInvocation;

  couchStreamControl = pkgs.writeShellApplication {
    name = "couch-stream-control";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.procps
      pkgs.systemd
    ];
    text = ''
      case "''${1:-}" in
        start)
          systemctl --user stop couch-moonlight-browser-stream.service >/dev/null 2>&1 || true
          systemctl --user stop couch-moonlight-browser-selector.service >/dev/null 2>&1 || true
          systemctl --user start couch-moonlight-stream.service
          ;;
        remote-browser)
          systemctl --user stop couch-moonlight-stream.service >/dev/null 2>&1 || true
          systemctl --user stop couch-moonlight-browser-selector.service >/dev/null 2>&1 || true
          systemctl --user start couch-moonlight-browser-stream.service
          # Starting an already-active unit is intentionally a no-op. Still
          # focus its window so the launch shortcut never appears to do
          # nothing, without forcing a dedicated output or workspace.
          hyprctl dispatch focuswindow \
            'class:^(com.moonlight_stream.Moonlight)$' >/dev/null 2>&1 || true
          ;;
        private-browser)
          systemctl --user stop couch-moonlight-stream.service >/dev/null 2>&1 || true
          systemctl --user stop couch-moonlight-browser-stream.service >/dev/null 2>&1 || true
          systemctl --user start couch-moonlight-browser-selector.service
          hyprctl dispatch focuswindow \
            'class:^(com.moonlight_stream.Moonlight)$' >/dev/null 2>&1 || true
          ;;
        browser)
          systemctl --user stop couch-moonlight-stream.service >/dev/null 2>&1 || true
          systemctl --user stop couch-moonlight-browser-stream.service >/dev/null 2>&1 || true
          systemctl --user stop couch-moonlight-browser-selector.service >/dev/null 2>&1 || true
          ${lib.getExe mergedUiControl} browser
          hyprctl dispatch workspace 2 >/dev/null 2>&1 || true

          if ! pgrep -u "$USER" -f -- ${lib.escapeShellArg cfg.browserProfileDirectory} \
            >/dev/null 2>&1; then
            ${lib.getExe couchBrowser} >/dev/null 2>&1 &
          fi
          ;;
        *)
          echo "usage: couch-stream-control {start|remote-browser|private-browser|browser}" >&2
          exit 2
          ;;
      esac
    '';
  };

  couchControlHelp = pkgs.writeShellApplication {
    name = "couch-control-help";
    text = ''
      dms="$HOME/.nix-profile/bin/dms"
      if [ ! -x "$dms" ]; then
        echo "DMS is not installed in the user profile" >&2
        exit 1
      fi

      exec "$dms" ipc call keybinds toggle xps-media-center
    '';
  };

  controllerPython = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.evdev ]);
  controllerDaemonSource = pkgs.writeText "couch-controller.py" ''
    import select
    import subprocess
    import time

    from evdev import InputDevice, ecodes, list_devices


    DEVICE_NAME = ${builtins.toJSON cfg.controllerDeviceName}
    HOLD_SECONDS = ${toString cfg.controllerHoldSeconds}
    ACTIONS = {
        "start": {ecodes.BTN_MODE, ecodes.BTN_EAST},
        ${lib.optionalString browserStreamEnabled ''
          "remote_browser": {ecodes.BTN_MODE, ecodes.BTN_NORTH},
        ''}
        "browser": {ecodes.BTN_THUMBL, ecodes.BTN_THUMBR},
        "help": {ecodes.BTN_SELECT, ecodes.BTN_SOUTH},
        ${lib.optionalString cfg.enableMirrorToggle ''
          "mirror": {ecodes.BTN_SELECT, ecodes.BTN_START},
        ''}
        ${lib.optionalString cfg.enableAdaptiveDisplayLayout ''
          "layout": {ecodes.BTN_SELECT, ecodes.BTN_NORTH},
        ''}
        ${lib.optionalString cfg.enableAudioOutputCycle ''
          "audio": {ecodes.BTN_SELECT, ecodes.BTN_WEST},
        ''}
    }
    COMMANDS = {
        "start": [${builtins.toJSON (lib.getExe couchStreamControl)}, "start"],
        ${lib.optionalString browserStreamEnabled ''
          "remote_browser": [${builtins.toJSON (lib.getExe couchStreamControl)}, "remote-browser"],
        ''}
        "browser": [${builtins.toJSON (lib.getExe couchStreamControl)}, "browser"],
        "help": [${builtins.toJSON (lib.getExe couchControlHelp)}],
        ${lib.optionalString cfg.enableMirrorToggle ''
          "mirror": [${builtins.toJSON (lib.getExe displayMirrorToggle)}, "toggle"],
        ''}
        ${lib.optionalString cfg.enableAdaptiveDisplayLayout ''
          "layout": [${builtins.toJSON (lib.getExe displayLayoutControl)}, "cycle"],
        ''}
        ${lib.optionalString cfg.enableAudioOutputCycle ''
          "audio": [${builtins.toJSON (lib.getExe audioOutputControl)}, "cycle"],
        ''}
    }


    def find_controller():
        for path in list_devices():
            device = InputDevice(path)
            if device.name == DEVICE_NAME and ecodes.EV_KEY in device.capabilities():
                return device
            device.close()
        return None


    def run_action(action):
        subprocess.Popen(
            COMMANDS[action],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )


    while True:
        controller = find_controller()
        if controller is None:
            time.sleep(2)
            continue

        pressed = set()
        started_at = {}
        triggered = set()

        try:
            while True:
                readable, _, _ = select.select([controller.fd], [], [], 0.1)
                if readable:
                    for event in controller.read():
                        if event.type != ecodes.EV_KEY:
                            continue
                        if event.value:
                            pressed.add(event.code)
                        else:
                            pressed.discard(event.code)

                now = time.monotonic()
                for action, buttons in ACTIONS.items():
                    if buttons.issubset(pressed):
                        started_at.setdefault(action, now)
                        if action not in triggered and now - started_at[action] >= HOLD_SECONDS:
                            run_action(action)
                            triggered.add(action)
                    else:
                        started_at.pop(action, None)
                        triggered.discard(action)
        except (OSError, ValueError):
            controller.close()
            time.sleep(1)
  '';

  controllerDaemon = pkgs.writeShellApplication {
    name = "couch-controller";
    text = ''
      exec ${controllerPython}/bin/python ${controllerDaemonSource}
    '';
  };

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

  audioOutputControl = pkgs.writeShellApplication {
    name = "couch-audio-output";
    runtimeInputs = [
      pkgs.gnused
      pkgs.hyprland
      pkgs.jq
      pkgs.pipewire
      pkgs.wireplumber
    ];
    text = ''
      get_sinks() {
        pw-dump | jq -c '
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
        '
      }

      sinks="$(get_sinks)"
      if [ "$(jq 'length' <<<"$sinks")" -eq 0 ]; then
        echo "no audio outputs are available" >&2
        exit 1
      fi

      current_id="$(
        wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null \
          | sed -n 's/^id \([0-9][0-9]*\),.*/\1/p' \
          | head -n1
      )"

      follow_layout() {
        current_api="$(
          jq -r --argjson current "''${current_id:--1}" \
            '.[] | select(.id == $current) | .api' <<<"$sinks"
        )"
        if [ "$current_api" = bluez5 ]; then
          return
        fi

        layout="$(tr -d '[:space:]' < ${lib.escapeShellArg displayLayoutStateFile} 2>/dev/null || true)"
        case "$layout" in
          solo-primary | primary-aux) target="Primary TV" ;;
          solo-secondary | secondary-aux) target="Secondary TV" ;;
          solo-tertiary) target="Auxiliary display" ;;
          *) return ;;
        esac
        target_id="$(
          jq -r --arg target "$target" \
            '[.[] | select(.description == $target)][0].id // ""' <<<"$sinks"
        )"
        if [ -n "$target_id" ]; then
          wpctl set-default "$target_id"
        fi
      }

      case "''${1:-cycle}" in
        initialize)
          for ((attempt = 0; attempt < 20; attempt++)); do
            if [ "$(jq '[.[] | select(.name | test("playback[.][0387][.]0$"))] | length' <<<"$sinks")" -ge 4 ]; then
              break
            fi
            sleep 0.25
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
          echo "usage: couch-audio-output {initialize|follow-layout|cycle|status}" >&2
          exit 2
          ;;
      esac

      description="$(
        jq -r --argjson id "$next_id" '.[] | select(.id == $id) | .description' \
          <<<"$sinks"
      )"
      wpctl set-default "$next_id"
      hyprctl notify 1 3000 'rgb(a6e3a1)' "Audio output: $description" \
        >/dev/null 2>&1 || true
      printf '%s\n' "$description"
    '';
  };

  displayLayoutControl = pkgs.writeShellApplication {
    name = "couch-display-layout";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
    ];
    text = ''
      state_file=${lib.escapeShellArg displayLayoutStateFile}
      current="$(
        if [ -r "$state_file" ]; then
          tr -d '[:space:]' < "$state_file"
        fi
      )"
      case "$current" in
        adaptive | all | dual-tvs | primary-aux | secondary-aux | solo-primary | solo-secondary | solo-tertiary) ;;
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
            all) requested=dual-tvs ;;
            dual-tvs) requested=primary-aux ;;
            primary-aux) requested=secondary-aux ;;
            secondary-aux) requested=solo-primary ;;
            solo-primary) requested=solo-secondary ;;
            solo-secondary) requested=solo-tertiary ;;
            *) requested=adaptive ;;
          esac
          ;;
        adaptive | all | dual-tvs | primary-aux | secondary-aux | solo-primary | solo-secondary | solo-tertiary)
          requested="$1"
          ;;
        *)
          echo "usage: couch-display-layout {status|cycle|adaptive|all|dual-tvs|primary-aux|secondary-aux|solo-primary|solo-secondary|solo-tertiary}" >&2
          exit 2
          ;;
      esac

      temporary_file="$state_file.tmp"
      printf '%s\n' "$requested" > "$temporary_file"
      mv "$temporary_file" "$state_file"
      ${lib.optionalString cfg.enableAudioOutputCycle ''
        ${lib.getExe audioOutputControl} follow-layout >/dev/null 2>&1 || true
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
    runtimeInputs = [
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
          allowed_workspaces="$(
            jq -cn \
              --argjson current "$allowed_workspaces" \
              --argjson tertiary ${lib.escapeShellArg (builtins.toJSON cfg.autoLayoutTertiaryWorkspaces)} \
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
            for workspace in ${lib.escapeShellArgs (map toString cfg.autoLayoutTertiaryWorkspaces)}; do
              default=""
              if [ "$workspace" = ${lib.escapeShellArg (toString (builtins.head cfg.autoLayoutTertiaryWorkspaces))} ]; then
                default=", default:true"
              fi
              printf 'workspace = %s, monitor:%s, persistent:true%s\n' \
                "$workspace" "$tertiary_output" "$default"
            done
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
          hyprctl dispatch workspace \
            ${lib.escapeShellArg (toString (builtins.head cfg.autoLayoutTertiaryWorkspaces))} \
            >/dev/null 2>&1 || true
          for workspace in ${lib.escapeShellArgs (map toString cfg.autoLayoutTertiaryWorkspaces)}; do
            hyprctl dispatch moveworkspacetomonitor \
              "$workspace" "$tertiary_output" >/dev/null 2>&1 || true
          done
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
            adaptive | all | dual-tvs | primary-aux | secondary-aux | solo-primary | solo-secondary | solo-tertiary) ;;
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
          dual-tvs)
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
          primary-aux | secondary-aux)
            external_monitors="$(
              jq -c \
                --arg layout "$display_layout" \
                --argjson minimum_width ${lib.escapeShellArg (toString cfg.autoLayoutPrimaryMinPhysicalWidth)} '
                if length == 0 then []
                else
                  (sort_by(.physicalWidth * .physicalHeight) | reverse) as $ranked
                  | ([$ranked[] | select(.physicalWidth >= $minimum_width)]) as $tvs
                  | ([$ranked[] | select(.physicalWidth < $minimum_width)]) as $auxiliary
                  | (if $layout == "primary-aux" then
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
          solo-primary | solo-secondary | solo-tertiary)
            external_monitors="$(
              jq -c \
                --arg layout "$display_layout" \
                --argjson minimum_width ${lib.escapeShellArg (toString cfg.autoLayoutPrimaryMinPhysicalWidth)} '
                if length == 0 then []
                else
                  (sort_by(.physicalWidth * .physicalHeight) | reverse) as $ranked
                  | ([$ranked[] | select(.physicalWidth >= $minimum_width)]) as $tvs
                  | ([$ranked[] | select(.physicalWidth < $minimum_width)]) as $auxiliary
                  | if $layout == "solo-primary" then
                      [($tvs[0] // $ranked[0])]
                    elif $layout == "solo-secondary" then
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
        native_mirror_allowed=${if cfg.forceSoftwareMirror then "0" else "1"}
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

  dmsSession = pkgs.writeShellApplication {
    name = "couch-dms";
    text = ''
      dms="$HOME/.nix-profile/bin/dms"
      if [ ! -x "$dms" ]; then
        echo "DMS is not installed in the user profile" >&2
        exit 1
      fi
      export PATH="$HOME/.nix-profile/bin:$PATH"
      exec "$dms" run
    '';
  };

  mergedDmsSession = pkgs.writeShellApplication {
    name = "couch-merged-dms";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
      displayLayoutControl
      displayMirrorToggle
      audioOutputControl
    ];
    text = ''
      mode="$(tr -d '[:space:]' < ${lib.escapeShellArg modeStateFile} 2>/dev/null || true)"
      if [ "$mode" != merged ]; then
        exit 0
      fi

      dms="$HOME/.nix-profile/bin/dms"
      if [ ! -x "$dms" ]; then
        echo "DMS is not installed in the user profile" >&2
        exit 1
      fi
      export PATH="$HOME/.nix-profile/bin:$PATH"

      config_home=${lib.escapeShellArg mergedDmsConfigDirectory}
      settings_directory="$config_home/DankMaterialShell"
      cheatsheets_directory="$settings_directory/cheatsheets"
      rm -rf "$config_home"
      install -d -m 0700 "$settings_directory" "$cheatsheets_directory"
      install -m 0600 ${mergedDmsSettingsFile} "$settings_directory/settings.json"
      install -m 0600 ${mergedDmsCheatsheetFile} \
        "$cheatsheets_directory/xps-media-center.json"

      plugin_settings="$HOME/.config/DankMaterialShell/plugin_settings.json"
      if [ -e "$plugin_settings" ]; then
        ln -s "$plugin_settings" "$settings_directory/plugin_settings.json"
      fi

      plugins_directory="$HOME/.config/DankMaterialShell/plugins"
      if [ -d "$plugins_directory" ]; then
        ln -s "$plugins_directory" "$settings_directory/plugins"
      fi

      export XDG_CONFIG_HOME="$config_home"
      exec "$dms" run
    '';
  };

  mergedDmsCondition = pkgs.writeShellApplication {
    name = "couch-merged-dms-condition";
    runtimeInputs = [ pkgs.gnugrep ];
    text = ''
      grep -qx merged ${lib.escapeShellArg modeStateFile}
    '';
  };

  waitForStableOutputs = pkgs.writeShellApplication {
    name = "couch-wait-for-stable-outputs";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
    ];
    text = ''
      # Give the layout daemon the first scheduling turn, then require the
      # visible output geometry to remain unchanged for one full second.
      sleep 0.5
      previous=""
      stable=0
      for _attempt in $(seq 1 100); do
        current="$(
          hyprctl -j monitors all 2>/dev/null \
            | jq -c '[
                .[]
                | select(.disabled == false and .dpmsStatus == true)
                | {
                    name,
                    x,
                    y,
                    width,
                    height,
                    refreshRate,
                    scale
                  }
              ] | sort_by(.name)' 2>/dev/null \
            || printf '[]\n'
        )"
        if [ "$current" != '[]' ] && [ "$current" = "$previous" ]; then
          stable=$((stable + 1))
        else
          stable=0
        fi
        previous="$current"
        if [ "$stable" -ge 10 ]; then
          exit 0
        fi
        sleep 0.1
      done
    '';
  };

  sessionSplashLaunch = pkgs.writeShellApplication {
    name = "couch-session-splash-launch";
    runtimeInputs = [ waitForStableOutputs ];
    text = ''
      couch-wait-for-stable-outputs
      # The compositor can render before a dock-connected TV has completed its
      # physical link recovery. Retained XPS boot timings put that gap at about
      # three seconds; keep the overlay loaded but do not consume its animation
      # clock during that interval.
      export NIXBOX_SPLASH_SETTLE_MS=3000
      exec ${
        if cfg.sessionSplashCommand == null then "${pkgs.coreutils}/bin/true" else cfg.sessionSplashCommand
      }
    '';
  };

  sessionPowerAction = pkgs.writeShellApplication {
    name = "couch-session-power-action";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      case "''${1:-}" in
        reboot)
          action=reboot
          mode=reboot
          ;;
        poweroff)
          action=poweroff
          mode=shutdown
          ;;
        *)
          echo "usage: couch-session-power-action {reboot|poweroff}" >&2
          exit 2
          ;;
      esac

      export NIXBOX_SPLASH_SETTLE_MS=0
      ${cfg.sessionSplashCommand} "$mode" &
      splash_pid=$!
      sleep 3.7
      if ! systemctl "$action"; then
        kill "$splash_pid" 2>/dev/null || true
        wait "$splash_pid" 2>/dev/null || true
        exit 1
      fi
      wait "$splash_pid" 2>/dev/null || true
    '';
  };

  mergedDmsServiceControl = pkgs.writeShellApplication {
    name = "couch-merged-dms-service-control";
    runtimeInputs = [
      pkgs.systemd
      waitForStableOutputs
    ];
    text = ''
      systemctl --user import-environment \
        WAYLAND_DISPLAY \
        HYPRLAND_INSTANCE_SIGNATURE \
        XDG_CURRENT_DESKTOP \
        DBUS_SESSION_BUS_ADDRESS
      couch-wait-for-stable-outputs
      exec systemctl --user restart couch-merged-dms.service
    '';
  };

  mergedUiControl = pkgs.writeShellApplication {
    name = "couch-merged-ui";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      mode="$(tr -d '[:space:]' < ${lib.escapeShellArg modeStateFile} 2>/dev/null || true)"
      if [ "$mode" != merged ]; then
        exit 0
      fi

      dms="$HOME/.nix-profile/bin/dms"
      if [ ! -x "$dms" ]; then
        exit 0
      fi

      case "''${1:-}" in
        game)
          "$dms" ipc call notifications enableDoNotDisturbIndefinitely >/dev/null 2>&1 || true
          "$dms" ipc call notifications dismissAllPopups >/dev/null 2>&1 || true
          "$dms" ipc call bar hide index 0 >/dev/null 2>&1 || true
          "$dms" ipc call dock hide >/dev/null 2>&1 || true
          ;;
        browser)
          for ((attempt = 0; attempt < 20; attempt++)); do
            if "$dms" ipc call bar reveal index 0 >/dev/null 2>&1; then
              break
            fi
            sleep 0.1
          done
          "$dms" ipc call bar autoHide index 0 >/dev/null 2>&1 || true
          "$dms" ipc call dock reveal >/dev/null 2>&1 || true
          "$dms" ipc call dock autoHide >/dev/null 2>&1 || true
          "$dms" ipc call notifications disableDoNotDisturb >/dev/null 2>&1 || true
          ;;
        *)
          echo "usage: couch-merged-ui {game|browser}" >&2
          exit 2
          ;;
      esac
    '';
  };

  sessionMode = pkgs.writeShellApplication {
    name = "xps-session-mode";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      mode_file=${lib.escapeShellArg modeStateFile}
      current="$(tr -d '[:space:]' < "$mode_file" 2>/dev/null || true)"

      if [ "$#" -eq 0 ]; then
        printf '%s\n' "''${current:-${cfg.defaultSessionMode}}"
        exit 0
      fi

      case "$1" in
        couch | desktop${lib.optionalString cfg.enableMergedProfile " | merged"})
          if [ "$1" = "$current" ]; then
            printf 'XPS is already configured for %s mode\n' "$1"
            exit 0
          fi
          printf '%s\n' "$1" > "$mode_file"
          printf 'Switching XPS to %s mode\n' "$1"
          ;;
        *)
          echo "usage: xps-session-mode [couch|desktop${lib.optionalString cfg.enableMergedProfile "|merged"}]" >&2
          exit 2
          ;;
      esac
    '';
  };

  couchApplications = pkgs.runCommand "couch-session-applications" { } ''
    mkdir -p "$out/share/applications"

    cat > "$out/share/applications/couch-browser.desktop" <<EOF
    [Desktop Entry]
    Name=Helium (Couch)
    Comment=Open the couch web browser
    Exec=${lib.getExe couchBrowser}
    Icon=helium
    Terminal=false
    Type=Application
    Categories=Network;WebBrowser;
    EOF

    ${lib.optionalString (cfg.fallbackBrowserPackage != null) ''
      cat > "$out/share/applications/couch-browser-fallback.desktop" <<EOF
      [Desktop Entry]
      Name=Brave (Couch fallback)
      Comment=Open the compatibility web browser
      Exec=${lib.getExe couchFallbackBrowser.package}
      Icon=brave-browser
      Terminal=false
      Type=Application
      Categories=Network;WebBrowser;
      EOF
    ''}

    ${lib.optionalString browserStreamEnabled ''
      cat > "$out/share/applications/couch-remote-browser.desktop" <<EOF
      [Desktop Entry]
      Name=Helium (Remote)
      Comment=Stream the public Helium browser through Moonlight and Wolf
      Exec=${lib.getExe couchStreamControl} remote-browser
      Icon=helium
      Terminal=false
      Type=Application
      Categories=Network;WebBrowser;
      EOF
    ''}

    ${lib.optionalString browserSelectorEnabled ''
      cat > "$out/share/applications/couch-private-browser.desktop" <<EOF
      [Desktop Entry]
      Name=User (Remote)
      Comment=Open the PIN-protected remote user profile
      Exec=${lib.getExe couchStreamControl} private-browser
      Icon=system-users
      Terminal=false
      Type=Application
      Categories=Network;WebBrowser;
      EOF
    ''}

    ${lib.optionalString cfg.enableControllerShortcuts ''
      cat > "$out/share/applications/couch-steam-stream.desktop" <<EOF
      [Desktop Entry]
      Name=Steam Stream
      Comment=Start Steam Big Picture through Moonlight
      Exec=${lib.getExe couchStreamControl} start
      Icon=steam
      Terminal=false
      Type=Application
      Categories=Game;
      EOF
    ''}

    ${lib.optionalString (cfg.desktopSessionCommand != null) ''
      cat > "$out/share/applications/xps-desktop-mode.desktop" <<EOF
      [Desktop Entry]
      Name=Switch to Desktop Mode
      Comment=Leave the couch session and start the normal desktop
      Exec=${lib.getExe sessionMode} desktop
      Icon=preferences-desktop
      Terminal=false
      Type=Application
      Categories=System;
      EOF

      cat > "$out/share/applications/xps-couch-mode.desktop" <<EOF
      [Desktop Entry]
      Name=Switch to Couch Mode
      Comment=Leave the desktop and start the TV couch session
      Exec=${lib.getExe sessionMode} couch
      Icon=video-display
      Terminal=false
      Type=Application
      Categories=System;
      EOF

      ${lib.optionalString cfg.enableMergedProfile ''
        cat > "$out/share/applications/xps-merged-mode.desktop" <<EOF
        [Desktop Entry]
        Name=Switch to Merged Couch Mode
        Comment=Use the controller-first TV session with an auto-hiding DMS shell
        Exec=${lib.getExe sessionMode} merged
        Icon=video-display
        Terminal=false
        Type=Application
        Categories=System;
        EOF
      ''}
    ''}
  '';

  hyprlandConfig = pkgs.writeText "moonlight-hyprland.conf" ''
    monitor = , ${defaultOutputMode}, auto, ${toString cfg.outputScale}
    ${lib.concatMapStringsSep "\n" (
      output: "monitor = ${output}, ${mirrorOutputMode}, 0x0, ${toString cfg.outputScale}"
    ) mirrorSourceOutputs}
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        output: source:
        "monitor = ${output}, ${mirrorOutputMode}, 0x0, ${toString cfg.outputScale}, mirror, ${source}"
      ) cfg.mirrorOutputs
    )}
    ${lib.concatStringsSep "\n" (map (rule: "monitor = ${rule}") cfg.extraMonitorRules)}
    ${lib.concatStringsSep "\n" (map (rule: "workspace = ${rule}") cfg.extraWorkspaceRules)}
    ${lib.optionalString dynamicExternalLayoutEnabled "source = ${dynamicMonitorConfigFile}"}
    ${lib.optionalString cfg.disableInternalDisplay ''
      monitor = eDP-1, disable
      monitor = LVDS-1, disable
    ''}

    env = QT_QPA_PLATFORM,wayland
    env = QT_QPA_PLATFORMTHEME,gtk3
    env = QT_QPA_PLATFORMTHEME_QT6,gtk3

    exec-once = ${pkgs.systemd}/bin/systemctl --user import-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP DBUS_SESSION_BUS_ADDRESS
    ${lib.optionalString dynamicExternalLayoutEnabled "exec-once = ${lib.getExe autoLayoutExternalOutputs}"}
    ${lib.optionalString (
      cfg.sessionSplashCommand != null
    ) "exec-once = ${lib.getExe sessionSplashLaunch}"}
    ${lib.optionalString cfg.autoStartBrowser "exec-once = ${
      lib.getExe (if cfg.preferRemoteBrowserAtStartup then couchBrowserStartup else couchBrowser)
    }"}
    ${lib.optionalString cfg.autoStartStream "exec-once = [workspace 1 silent] ${lib.getExe moonlightSession}"}
    ${lib.optionalString cfg.enableControllerShortcuts "exec-once = ${lib.getExe controllerDaemon}"}
    ${lib.optionalString cfg.enableAudioOutputCycle "exec-once = ${lib.getExe audioOutputControl} initialize"}
    # Hyprland's portal does not implement RemoteDesktop. Keep KDE Connect and
    # couch browsers on XWayland so its phone keyboard, clicks, and scrolling
    # can be injected through XTest. Do not mirror the X11 pointer into
    # Hyprland: doing so fights physical pointer motion over XWayland surfaces.
    ${lib.optionalString cfg.enableKdeConnect "exec-once = ${pkgs.coreutils}/bin/env QT_QPA_PLATFORM=xcb ${lib.getExe' pkgs.kdePackages.kdeconnect-kde "kdeconnectd"}"}
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        output: source:
        "exec-once = ${lib.getExe softwareMirror} ${lib.escapeShellArg output} ${lib.escapeShellArg source}"
      ) cfg.softwareMirrorOutputs
    )}
    ${lib.optionalString cfg.enableDms "exec-once = ${lib.getExe dmsSession}"}
    ${lib.optionalString cfg.enableMergedProfile "exec-once = ${lib.getExe mergedDmsServiceControl}"}

    input {
      kb_layout = ${cfg.keyboardLayouts}
      kb_options = ${cfg.keyboardOptions}
      numlock_by_default = true

      touchpad {
        natural_scroll = true
      }
    }

    # The couch controls must remain available while Moonlight or another
    # fullscreen client asks the compositor to inhibit global shortcuts.
    binds {
      disable_keybind_grabbing = true
    }

    general {
      gaps_in = 0
      gaps_out = 0
      border_size = 0
    }

    decoration {
      rounding = 0

      shadow {
        enabled = false
      }
    }

    animations {
      enabled = false
    }

    misc {
      disable_hyprland_logo = true
      disable_splash_rendering = true
      background_color = rgb(0b0c0f)
    }

    cursor {
      inactive_timeout = 3
    }

    windowrule = match:class CouchBrowser, workspace 2
    bind = SUPER, 1, exec, ${lib.getExe couchWorkspace} switch 1
    bind = SUPER, 2, exec, ${lib.getExe couchWorkspace} switch 2
    bind = SUPER, 3, exec, ${lib.getExe couchWorkspace} switch 3
    bind = SUPER, 4, exec, ${lib.getExe couchWorkspace} switch 4
    bind = SUPER, 5, exec, ${lib.getExe couchWorkspace} switch 5
    bind = SUPER, 6, exec, ${lib.getExe couchWorkspace} switch 6
    bind = SUPER, 7, exec, ${lib.getExe couchWorkspace} switch 7
    bind = SUPER, 8, exec, ${lib.getExe couchWorkspace} switch 8
    bind = SUPER, 9, exec, ${lib.getExe couchWorkspace} switch 9
    ${
      if cfg.enableControllerShortcuts then
        "bind = SUPER, M, exec, ${lib.getExe couchStreamControl} start"
      else
        "bind = SUPER, M, workspace, 1"
    }
    bind = SUPER, B, exec, ${lib.getExe couchStreamControl} browser
    ${lib.optionalString browserStreamEnabled "bind = SUPER, R, exec, ${lib.getExe couchStreamControl} remote-browser"}
    ${lib.optionalString browserSelectorEnabled "bind = SUPER SHIFT, R, exec, ${lib.getExe couchStreamControl} private-browser"}
    ${lib.optionalString cfg.enableMirrorToggle "bind = SUPER SHIFT, M, exec, ${lib.getExe displayMirrorToggle} toggle"}
    ${lib.optionalString cfg.enableAdaptiveDisplayLayout "bind = SUPER SHIFT, D, exec, ${lib.getExe displayLayoutControl} cycle"}
    ${lib.optionalString cfg.enableAudioOutputCycle "bind = SUPER SHIFT, A, exec, ${lib.getExe audioOutputControl} cycle"}
    bind = SUPER, H, exec, ${lib.getExe couchControlHelp}
    bind = SUPER, V, exec, ${lib.getExe couchBrowserNewWindow}
    ${lib.optionalString (
      cfg.protectedBrowserPackage != null
    ) "bind = SUPER, Z, exec, ${lib.getExe protectedBrowser}"}
    bind = ALT, RETURN, exec, ${lib.getExe couchTerminal}
    ${lib.optionalString (
      cfg.enableDms || cfg.enableMergedProfile
    ) "bind = SUPER, SPACE, exec, $HOME/.nix-profile/bin/dms ipc call spotlight toggle"}
    bind = SUPER, W, killactive
    bind = SUPER, RETURN, fullscreen
    bind = SUPER, S, togglefloating

    bind = SUPER, J, exec, ${lib.getExe couchWorkspace} previous
    bind = SUPER, K, exec, ${lib.getExe couchWorkspace} next
    bind = SUPER, down, exec, ${lib.getExe couchWorkspace} previous
    bind = SUPER, up, exec, ${lib.getExe couchWorkspace} next
    bind = SUPER, TAB, workspace, previous

    bind = SUPER SHIFT, J, exec, ${lib.getExe couchWorkspace} move-previous
    bind = SUPER SHIFT, K, exec, ${lib.getExe couchWorkspace} move-next
    bind = SUPER SHIFT, down, exec, ${lib.getExe couchWorkspace} move-previous
    bind = SUPER SHIFT, up, exec, ${lib.getExe couchWorkspace} move-next
    bind = SUPER SHIFT, 1, exec, ${lib.getExe couchWorkspace} move 1
    bind = SUPER SHIFT, 2, exec, ${lib.getExe couchWorkspace} move 2
    bind = SUPER SHIFT, 3, exec, ${lib.getExe couchWorkspace} move 3
    bind = SUPER SHIFT, 4, exec, ${lib.getExe couchWorkspace} move 4
    bind = SUPER SHIFT, 5, exec, ${lib.getExe couchWorkspace} move 5
    bind = SUPER SHIFT, 6, exec, ${lib.getExe couchWorkspace} move 6
    bind = SUPER SHIFT, 7, exec, ${lib.getExe couchWorkspace} move 7
    bind = SUPER SHIFT, 8, exec, ${lib.getExe couchWorkspace} move 8
    bind = SUPER SHIFT, 9, exec, ${lib.getExe couchWorkspace} move 9

    bindel = , XF86AudioRaiseVolume, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-volume @DEFAULT_AUDIO_SINK@ 3%+
    bindel = , XF86AudioLowerVolume, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-volume @DEFAULT_AUDIO_SINK@ 3%-
    bindl = , XF86AudioMute, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-mute @DEFAULT_AUDIO_SINK@ toggle
    bindel = , F10, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-volume @DEFAULT_AUDIO_SINK@ 3%+
    bindel = , F9, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-volume @DEFAULT_AUDIO_SINK@ 3%-
    bindl = , F8, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-mute @DEFAULT_AUDIO_SINK@ toggle

    # Emergency exit back to greetd if the couch session cannot be closed normally.
    bind = SUPER SHIFT, escape, exit
    bind = SUPER SHIFT, Q, exit
  '';

  sessionLauncher = pkgs.writeShellScript "moonlight-hyprland-session" ''
    # Hyprland writes its startup banner and backend discovery to the launch
    # TTY before the first frame. Its own per-session log remains available
    # under XDG_RUNTIME_DIR, so keep the media-center handoff visually quiet.
    exec ${pkgs.hyprland}/bin/start-hyprland -- --config ${hyprlandConfig} \
      >/dev/null 2>&1
  '';

  sessionPackage = pkgs.writeTextFile {
    name = "moonlight-hyprland-session";
    destination = "/share/wayland-sessions/moonlight-hyprland.desktop";
    passthru.providedSessions = [ "moonlight-hyprland" ];
    text = ''
      [Desktop Entry]
      Name=Couch (Hyprland)
      Comment=Moonlight, browser, and phone-friendly TV session
      Exec=${sessionLauncher}
      Type=Application
      DesktopNames=Hyprland
    '';
  };

  sessionCommand = sessionLauncher;

  sessionDispatcher = pkgs.writeShellApplication {
    name = "couch-session-dispatcher";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      mode="$(tr -d '[:space:]' < ${lib.escapeShellArg modeStateFile} 2>/dev/null || true)"
      if [ "$mode" != merged ]; then
        systemctl --user stop couch-merged-dms.service >/dev/null 2>&1 || true
      fi
      case "$mode" in
        desktop)
          exec ${cfg.desktopSessionCommand}
          ;;
        ${lib.optionalString cfg.enableMergedProfile ''
          merged)
            exec ${sessionCommand}
            ;;
        ''}
        couch | *)
          exec ${sessionCommand}
          ;;
      esac
    '';
  };
in
{
  options.services.moonlight-client = {
    enable = lib.mkEnableOption "a dedicated Moonlight Hyprland session";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.moonlight-qt;
      defaultText = lib.literalExpression "pkgs.moonlight-qt";
      description = "Moonlight package used by the dedicated session.";
    };

    autoLoginUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "User to log directly into the Moonlight session on boot, or null to use the display manager.";
    };

    relaunchOnExit = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Relaunch Moonlight when it exits so the session remains controller accessible.";
    };

    autoStartStream = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Launch Moonlight when the couch session starts.";
    };

    autoStartBrowser = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Launch the couch browser when the couch session starts.";
    };

    preferRemoteBrowserAtStartup = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Prefer the configured remote browser when the couch session starts,
        falling back to the local couch browser when its Sunshine endpoint is
        unavailable.
      '';
    };

    browserStartupTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Seconds to wait for the remote browser before starting the local fallback.";
    };

    sessionSplashCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional non-blocking command launched before couch-session applications.";
    };

    moonlightPlatform = lib.mkOption {
      type = lib.types.enum [
        "wayland"
        "xcb"
      ];
      default = "wayland";
      description = "Qt platform used by Moonlight; xcb permits KDE Connect XTest input.";
    };

    streamHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Paired Moonlight host to stream immediately, or null to open the host chooser.";
    };

    streamApplication = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Moonlight application to launch on streamHost, or null to open the host chooser.";
    };

    streamLocalAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Preferred RFC 1918 address for the direct stream host.";
    };

    streamRemoteAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "VPN fallback address for the direct stream host.";
    };

    browserStreamHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Paired Moonlight host providing the controller-launched remote browser.";
    };

    browserStreamApplication = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Moonlight application used as the public remote browser.";
    };

    browserStreamSelectorApplication = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional Moonlight application used as a separate protected-profile
        selector on the same remote browser host.
      '';
    };

    browserStreamLocalAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Preferred RFC 1918 address for the remote browser host.";
    };

    browserStreamRemoteAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "VPN fallback address for the remote browser host.";
    };

    browserStreamArguments = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional Moonlight arguments used only for the remote browser stream.";
    };

    streamArguments = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional arguments passed to the direct Moonlight stream command.";
    };

    streamHostStartCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Optional command that starts the remote stream host before Moonlight.";
    };

    streamReadinessHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host whose Sunshine port must become reachable before Moonlight starts.";
    };

    streamReadinessPort = lib.mkOption {
      type = lib.types.port;
      default = 47989;
      description = "TCP port used to determine whether the stream host is ready.";
    };

    streamHostControlPort = lib.mkOption {
      type = lib.types.port;
      default = 22;
      description = ''
        TCP port used to choose the LAN-first host address exported to the
        stream host start command as COUCH_STREAM_START_TARGET.
      '';
    };

    streamStartupTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 90;
      description = "Seconds to wait for the stream host after requesting startup.";
    };

    enableControllerShortcuts = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Listen for held controller shortcuts that start streaming or return to the browser.";
    };

    controllerDeviceName = lib.mkOption {
      type = lib.types.str;
      default = "Pro Controller";
      description = "Linux input device name used for couch controller shortcuts.";
    };

    controllerHoldSeconds = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = "Time a controller shortcut must be held before it is activated.";
    };

    enableDms = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Start DMS from the user's Home Manager profile in the dedicated session.";
    };

    enableMergedProfile = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Offer a third dedicated session profile with isolated, couch-friendly DMS settings.";
    };

    mergedDmsSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {
        acMonitorTimeout = 0;
        acLockTimeout = 0;
        acSuspendTimeout = 0;
        acPostLockMonitorTimeout = 0;
        batteryMonitorTimeout = 0;
        batteryLockTimeout = 0;
        batterySuspendTimeout = 0;
        batteryPostLockMonitorTimeout = 0;
        loginctlLockIntegration = false;
        lockBeforeSuspend = false;
        lockAtStartup = false;
        fadeToLockEnabled = false;
        fadeToDpmsEnabled = false;
        soundsEnabled = false;
        # DMS's native surfaces are otherwise too small to read at couch
        # distance on a 1440p television. This config is isolated from the
        # normal desktop profile.
        fontScale = 2.0;
        showDock = true;
        dockAutoHide = true;
        dockSmartAutoHide = true;
        notificationOverlayEnabled = false;
        barConfigs = [
          {
            id = "merged";
            name = "Couch Bar";
            enabled = true;
            position = 0;
            screenPreferences = [ "all" ];
            showOnLastDisplay = true;
            leftWidgets = [
              "launcherButton"
              "workspaceSwitcher"
              "focusedWindow"
            ];
            centerWidgets = [
              "music"
              "clock"
            ];
            rightWidgets = [
              "dankDisplayControl"
              "systemTray"
              "notificationButton"
              "battery"
              "controlCenterButton"
            ];
            spacing = 4;
            innerPadding = 4;
            bottomGap = 0;
            transparency = 1.0;
            widgetTransparency = 1.0;
            autoHide = true;
            autoHideStrict = true;
            autoHideDelay = 250;
            showOnWindowsOpen = false;
            openOnOverview = false;
            visible = true;
            popupGapsAuto = true;
            popupGapsManual = 4;
            useOverlayLayer = false;
          }
        ];
      };
      description = "DMS settings used only by the isolated merged couch profile.";
    };

    enableKdeConnect = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable KDE Connect and start its daemon in the dedicated session.";
    };

    keyboardLayouts = lib.mkOption {
      type = lib.types.str;
      default = "us,no";
      description = "Comma-separated XKB layouts used by the dedicated couch session, in default-first order.";
    };

    keyboardOptions = lib.mkOption {
      type = lib.types.str;
      default = "grp:alt_shift_toggle";
      description = "XKB options used by the dedicated couch session.";
    };

    browserPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.helium;
      defaultText = lib.literalExpression "pkgs.helium";
      description = "Browser package used by the couch browser launcher.";
    };

    browserScaleFactor = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = "Chromium device scale factor used by couch browser launchers.";
    };

    terminalPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.foot;
      defaultText = lib.literalExpression "pkgs.foot";
      description = "Terminal package opened by the couch-session terminal shortcut.";
    };

    browserProfileDirectory = lib.mkOption {
      type = lib.types.str;
      default = "helium-couch";
      description = "Directory below ~/.local/share used for the couch browser profile.";
    };

    fallbackBrowserPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = pkgs.brave;
      defaultText = lib.literalExpression "pkgs.brave";
      description = "Optional compatibility browser package used by the couch session.";
    };

    fallbackBrowserProfileDirectory = lib.mkOption {
      type = lib.types.str;
      default = "brave-couch";
      description = "Directory below ~/.local/share used for the fallback browser profile.";
    };

    protectedBrowserPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Browser package whose data directory is kept in a password-protected gocryptfs mount.";
    };

    protectedBrowserName = lib.mkOption {
      type = lib.types.str;
      default = "Private browser";
      description = "Name shown for the password-protected browser launcher.";
    };

    protectedBrowserIcon = lib.mkOption {
      type = lib.types.str;
      default = "web-browser";
      description = "Icon name or absolute path used by the protected browser desktop entry.";
    };

    protectedBrowserCommandName = lib.mkOption {
      type = lib.types.str;
      default = "couch-protected-browser";
      description = "Command name installed for the protected browser launcher.";
    };

    protectedBrowserEncryptedDirectory = lib.mkOption {
      type = lib.types.str;
      default = "couch-protected-browser";
      description = "Directory below ~/.local/share that stores the encrypted browser data.";
    };

    protectedBrowserRuntimeDirectory = lib.mkOption {
      type = lib.types.str;
      default = "couch-protected-browser";
      description = "Directory below XDG_RUNTIME_DIR used for the unlocked browser mount.";
    };

    protectedBrowserLegacyProfileDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional existing browser data directory to migrate into an empty protected profile.";
    };

    desktopSessionCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Command for the normal desktop session, or null to disable persistent mode switching.";
    };

    defaultSessionMode = lib.mkOption {
      type = lib.types.enum [
        "couch"
        "desktop"
        "merged"
      ];
      default = "couch";
      description = "Session mode used until the user selects and persists another mode.";
    };

    disableInternalDisplay = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable common laptop panels while retaining the preferred external display.";
    };

    outputScale = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = "Hyprland scale used for the Moonlight display.";
    };

    outputMode = lib.mkOption {
      type = lib.types.str;
      default = "preferred";
      description = "Hyprland mode used for the Moonlight display.";
    };

    mirrorOutputs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "DP-2" = "DP-1";
      };
      description = "External outputs to mirror, expressed as target-to-source connector mappings.";
    };

    mirrorOutputMode = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Shared mode for mirrored outputs, or null to use outputMode.";
    };

    extraMonitorRules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "DP-2, 3840x2160@60, 2560x0, 2" ];
      description = "Additional Hyprland monitor rule bodies applied after the default and native mirror rules.";
    };

    extraWorkspaceRules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "10, monitor:DP-2, default:true" ];
      description = "Additional Hyprland workspace rule bodies for fixed multi-output couch layouts.";
    };

    softwareMirrorOutputs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "DP-2" = "DP-1";
      };
      description = "Outputs mirrored in a supervised fullscreen wl-mirror client, expressed as target-to-source mappings.";
    };

    autoMirrorExternalOutputs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Supervise a software mirror from the discovered primary external output to the secondary output.";
    };

    enableMirrorToggle = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable an on-demand mirror toggle from the primary to the secondary external output, using native mirroring for matching modes and software mirroring otherwise.";
    };

    forceSoftwareMirror = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use the supervised wl-mirror path for on-demand mirroring even when output modes match.";
    };

    enableAdaptiveDisplayLayout = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Preserve the currently active external output with persistent all-output and solo-output recovery modes.";
    };

    enableAudioOutputCycle = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable keyboard and controller shortcuts that cycle the available PipeWire audio sinks.";
    };

    audioOutputStartupVolumePercent = lib.mkOption {
      type = lib.types.ints.between 0 100;
      default = 40;
      description = "Safe startup volume applied to the persistent local couch audio sinks.";
    };

    autoLayoutExternalOutputs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Dynamically lay out external outputs and move their workspace sets across connector changes.";
    };

    autoLayoutSecondaryModes = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      default = [ "1920x1080@60" ];
      description = "Preferred modes for automatically discovered auxiliary outputs, in priority order.";
    };

    autoLayoutSecondaryPosition = lib.mkOption {
      type = lib.types.str;
      default = "2560x0";
      description = "Hyprland position used by the automatically discovered secondary output.";
    };

    autoMirrorSecondaryPosition = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Hyprland position used by the secondary output while on-demand mirroring is enabled, or null to retain autoLayoutSecondaryPosition.";
    };

    autoLayoutSecondaryScale = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = "Hyprland scale used by the automatically discovered secondary output.";
    };

    autoLayoutTertiaryPosition = lib.mkOption {
      type = lib.types.str;
      default = "5120x0";
      description = "Hyprland position used by the automatically discovered tertiary output.";
    };

    autoMirrorTertiaryPosition = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Hyprland position used by the tertiary output while on-demand mirroring is enabled, or null to retain autoLayoutTertiaryPosition.";
    };

    autoLayoutTertiaryScale = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = "Hyprland scale used by the automatically discovered tertiary output.";
    };

    autoLayoutPrimaryMinPhysicalWidth = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1000;
      description = "Minimum reported physical width in millimetres for an external output to become the automatic mirror source.";
    };

    autoLayoutPrimaryWorkspaces = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.ints.positive;
      default = [
        1
        2
        3
        4
        5
      ];
      description = "Persistent workspaces assigned to the discovered primary output.";
    };

    autoLayoutSecondaryWorkspaces = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.ints.positive;
      default = [
        6
        7
        8
        9
        10
      ];
      description = "Persistent workspaces assigned while the secondary output is an independent logical display.";
    };

    autoLayoutTertiaryWorkspaces = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.ints.positive;
      default = [
        11
        12
        13
      ];
      description = "Persistent workspaces assigned while the tertiary output is an independent logical display.";
    };

    autoMirrorWorkspace = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Dedicated workspace used by the automatic fullscreen software mirror.";
    };

    fallbackOutputMode = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Mode to apply when the external display does not enter outputMode, or null to keep Hyprland's result.";
    };

    preferHdmiAudio = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Select the first available HDMI sink before starting Moonlight.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
      cfg.browserPackage
      cfg.terminalPackage
      couchBrowser
      couchBrowserStartup
      couchBrowserNewWindow
      couchTerminal
      couchApplications
      couchStreamControl
      moonlightStreamStart
    ]
    ++ lib.optional cfg.enableControllerShortcuts controllerDaemon
    ++ lib.optional cfg.enableControllerShortcuts couchControlHelp
    ++ lib.optional cfg.enableMergedProfile mergedDmsSession
    ++ lib.optional cfg.enableMergedProfile mergedUiControl
    ++ lib.optional (cfg.softwareMirrorOutputs != { }) softwareMirror
    ++ lib.optional cfg.enableMirrorToggle displayMirrorToggle
    ++ lib.optional cfg.enableAdaptiveDisplayLayout displayLayoutControl
    ++ lib.optional cfg.enableAudioOutputCycle audioOutputControl
    ++ lib.optional dynamicExternalLayoutEnabled autoLayoutExternalOutputs
    ++ lib.optional (cfg.fallbackBrowserPackage != null) cfg.fallbackBrowserPackage
    ++ lib.optional (cfg.fallbackBrowserPackage != null) couchFallbackBrowser.package
    ++ lib.optional (cfg.protectedBrowserPackage != null) protectedBrowser
    ++ lib.optional (cfg.desktopSessionCommand != null) sessionMode;
    services.displayManager.sessionPackages = [ sessionPackage ];

    # Install udev rules for common controllers, including Steam hardware.
    hardware.steam-hardware.enable = true;

    programs.kdeconnect.enable = cfg.enableKdeConnect;

    systemd.user.services.couch-moonlight-stream = lib.mkIf cfg.enableControllerShortcuts {
      description = "Controller-launched Moonlight stream";
      serviceConfig = {
        Type = "simple";
        ExecStartPre = "-${lib.getExe mergedUiControl} game";
        ExecStart = lib.getExe moonlightStreamStart;
        ExecStopPost = [
          "-${lib.getExe mergedUiControl} browser"
          "-${pkgs.hyprland}/bin/hyprctl dispatch workspace 2"
        ];
        TimeoutStartSec = cfg.streamStartupTimeout + 30;
      };
    };

    systemd.user.services.couch-moonlight-browser-stream = lib.mkIf browserStreamEnabled {
      description = "Controller-launched remote browser stream";
      serviceConfig = {
        Type = "simple";
        ExecStartPre = "-${lib.getExe mergedUiControl} game";
        ExecStart = lib.getExe moonlightBrowserSession;
        ExecStopPost = [
          "-${lib.getExe mergedUiControl} browser"
          "-${pkgs.hyprland}/bin/hyprctl dispatch workspace 2"
        ];
      };
    };

    systemd.user.services.couch-moonlight-browser-selector = lib.mkIf browserSelectorEnabled {
      description = "PIN-protected remote browser selector";
      serviceConfig = {
        Type = "simple";
        ExecStartPre = "-${lib.getExe mergedUiControl} game";
        ExecStart = lib.getExe moonlightBrowserSelectorSession;
        ExecStopPost = [
          "-${lib.getExe mergedUiControl} browser"
          "-${pkgs.hyprland}/bin/hyprctl dispatch workspace 2"
        ];
      };
    };

    systemd.user.services.couch-protected-browser = lib.mkIf (cfg.protectedBrowserPackage != null) {
      description = "Independent protected couch browser supervisor";
      serviceConfig = {
        Type = "exec";
        ExecStart = lib.getExe protectedBrowserSession;
      };
    };

    systemd.user.services.couch-merged-dms = lib.mkIf cfg.enableMergedProfile {
      description = "Supervised DMS shell for the merged couch session";
      serviceConfig = {
        Type = "simple";
        ExecCondition = lib.getExe mergedDmsCondition;
        ExecStart = lib.getExe mergedDmsSession;
        Restart = "always";
        RestartSec = 2;
        SuccessExitStatus = 143;
      };
    };

    services.greetd.settings.initial_session = lib.mkIf (cfg.autoLoginUser != null) {
      command =
        if cfg.desktopSessionCommand == null then sessionCommand else lib.getExe sessionDispatcher;
      user = cfg.autoLoginUser;
    };

    systemd.tmpfiles.rules =
      lib.optional (
        cfg.autoLoginUser != null && (cfg.desktopSessionCommand != null || cfg.enableAdaptiveDisplayLayout)
      ) "d ${modeStateDirectory} 0755 ${cfg.autoLoginUser} root - -"
      ++ lib.optional (
        cfg.autoLoginUser != null && cfg.desktopSessionCommand != null
      ) "f ${modeStateFile} 0644 ${cfg.autoLoginUser} root - ${cfg.defaultSessionMode}"
      ++ lib.optional (
        cfg.autoLoginUser != null && cfg.enableAdaptiveDisplayLayout
      ) "f ${displayLayoutStateFile} 0644 ${cfg.autoLoginUser} root - adaptive"
      ++ lib.optional (
        cfg.autoLoginUser != null && dynamicExternalLayoutEnabled
      ) "d ${runtimeStateDirectory} 0755 ${cfg.autoLoginUser} root - -"
      ++ lib.optional (
        cfg.autoLoginUser != null && dynamicExternalLayoutEnabled
      ) "f ${dynamicMonitorConfigFile} 0644 ${cfg.autoLoginUser} root -"
      ++ lib.optional (
        cfg.autoLoginUser != null && cfg.enableMirrorToggle
      ) "f ${mirrorStateFile} 0644 ${cfg.autoLoginUser} root - 0";

    systemd.paths.couch-session-mode-switch =
      lib.mkIf (cfg.autoLoginUser != null && cfg.desktopSessionCommand != null)
        {
          description = "Watch for XPS session mode changes";
          wantedBy = [ "multi-user.target" ];
          pathConfig = {
            PathChanged = modeStateFile;
            Unit = "couch-session-mode-switch.service";
          };
        };

    systemd.services.couch-session-mode-switch =
      lib.mkIf (cfg.autoLoginUser != null && cfg.desktopSessionCommand != null)
        {
          description = "Restart greetd after an XPS session mode change";
          serviceConfig.Type = "oneshot";
          script = ''
            # initial_session runs once per boot unless greetd's ephemeral marker is
            # cleared. A deliberate mode change should auto-login immediately.
            rm -f /run/greetd.run
            ${pkgs.systemd}/bin/systemctl try-restart greetd.service
          '';
        };

    assertions = [
      {
        assertion = cfg.autoLoginUser == null || config.services.greetd.enable;
        message = "services.moonlight-client.autoLoginUser requires services.greetd.enable";
      }
      {
        assertion = cfg.desktopSessionCommand == null || cfg.autoLoginUser != null;
        message = "services.moonlight-client.desktopSessionCommand requires autoLoginUser";
      }
      {
        assertion = cfg.defaultSessionMode != "merged" || cfg.enableMergedProfile;
        message = "services.moonlight-client.defaultSessionMode = merged requires enableMergedProfile";
      }
      {
        assertion = (cfg.streamHost == null) == (cfg.streamApplication == null);
        message = "services.moonlight-client.streamHost and streamApplication must be set together";
      }
      {
        assertion = (cfg.browserStreamHost == null) == (cfg.browserStreamApplication == null);
        message = "services.moonlight-client.browserStreamHost and browserStreamApplication must be set together";
      }
      {
        assertion = (cfg.streamLocalAddress == null) == (cfg.streamRemoteAddress == null);
        message = "services.moonlight-client stream local and remote addresses must be set together";
      }
      {
        assertion = !streamEndpointPolicyEnabled || directStreamEnabled;
        message = "services.moonlight-client stream endpoint policy requires a direct stream";
      }
      {
        assertion = (cfg.browserStreamLocalAddress == null) == (cfg.browserStreamRemoteAddress == null);
        message = "services.moonlight-client browser stream local and remote addresses must be set together";
      }
      {
        assertion = !browserStreamEndpointPolicyEnabled || browserStreamEnabled;
        message = "services.moonlight-client browser endpoint policy requires a browser stream";
      }
      {
        assertion = !cfg.preferRemoteBrowserAtStartup || (cfg.autoStartBrowser && browserStreamEnabled);
        message = ''
          services.moonlight-client.preferRemoteBrowserAtStartup requires
          autoStartBrowser and a configured remote browser stream
        '';
      }
      {
        assertion = cfg.browserStreamSelectorApplication == null || browserStreamEnabled;
        message = "services.moonlight-client browser selector requires a browser stream host and application";
      }
      {
        assertion = !cfg.enableControllerShortcuts || directStreamEnabled;
        message = "services.moonlight-client.enableControllerShortcuts requires a direct stream host and application";
      }
      {
        assertion = cfg.controllerHoldSeconds > 0.0;
        message = "services.moonlight-client.controllerHoldSeconds must be positive";
      }
      {
        assertion = cfg.browserScaleFactor > 0.0;
        message = "services.moonlight-client.browserScaleFactor must be positive";
      }
      {
        assertion = lib.all (output: output != cfg.mirrorOutputs.${output}) (
          lib.attrNames cfg.mirrorOutputs
        );
        message = "services.moonlight-client.mirrorOutputs cannot mirror an output to itself";
      }
      {
        assertion = lib.all (output: output != cfg.softwareMirrorOutputs.${output}) (
          lib.attrNames cfg.softwareMirrorOutputs
        );
        message = "services.moonlight-client.softwareMirrorOutputs cannot mirror an output to itself";
      }
      {
        assertion = !dynamicExternalLayoutEnabled || cfg.autoLoginUser != null;
        message = "services.moonlight-client automatic external-output layout requires autoLoginUser";
      }
      {
        assertion =
          lib.intersectLists cfg.autoLayoutPrimaryWorkspaces cfg.autoLayoutSecondaryWorkspaces == [ ];
        message = "services.moonlight-client automatic primary and secondary workspace sets must not overlap";
      }
      {
        assertion =
          lib.intersectLists cfg.autoLayoutPrimaryWorkspaces cfg.autoLayoutTertiaryWorkspaces == [ ]
          && lib.intersectLists cfg.autoLayoutSecondaryWorkspaces cfg.autoLayoutTertiaryWorkspaces == [ ];
        message = "services.moonlight-client automatic tertiary workspace set must not overlap the primary or secondary sets";
      }
      {
        assertion =
          lib.elem 1 cfg.autoLayoutPrimaryWorkspaces && lib.elem 2 cfg.autoLayoutPrimaryWorkspaces;
        message = "services.moonlight-client automatic primary workspace set must contain stream workspace 1 and browser workspace 2";
      }
      {
        assertion =
          !cfg.autoMirrorExternalOutputs
          || lib.elem cfg.autoMirrorWorkspace cfg.autoLayoutSecondaryWorkspaces;
        message = "services.moonlight-client.autoMirrorWorkspace must belong to the secondary workspace set";
      }
      {
        assertion = !cfg.enableMirrorToggle || cfg.autoLayoutExternalOutputs;
        message = "services.moonlight-client.enableMirrorToggle requires autoLayoutExternalOutputs";
      }
      {
        assertion = !cfg.forceSoftwareMirror || cfg.enableMirrorToggle;
        message = "services.moonlight-client.forceSoftwareMirror requires enableMirrorToggle";
      }
      {
        assertion = !cfg.enableAdaptiveDisplayLayout || cfg.autoLayoutExternalOutputs;
        message = "services.moonlight-client.enableAdaptiveDisplayLayout requires autoLayoutExternalOutputs";
      }
      {
        assertion = !cfg.enableMirrorToggle || !cfg.autoMirrorExternalOutputs;
        message = "services.moonlight-client on-demand and automatic mirroring are mutually exclusive";
      }
    ];
  };
}
