{
  activeKeyboardLayout,
  browserMoonlightInvocation,
  browserSelectorEndpointSetup,
  browserSelectorMoonlightInvocation,
  browserStreamReadinessHosts,
  cfg,
  directStreamEnabled,
  displayModeSetup,
  hdmiAudioSetup,
  lib,
  moonlightEndpointSetup,
  moonlightInvocation,
  moonlightPackage,
  pkgs,
  streamReadinessHosts,
}: let
  superviseMoonlightWindow = targetWorkspace: ''
    seen_window=0
    startup_window_checks=0
    missing_window_checks=0
    moonlight_address=""
    placed_moonlight_address=""

    terminate_moonlight() {
      kill "$moonlight_pid" >/dev/null 2>&1 || true
      sleep 1
      kill -KILL "$moonlight_pid" >/dev/null 2>&1 || true
    }

    # systemd stops the supervising shell first. Explicitly reap Moonlight so
    # a restart cannot leave the old client holding SDL input/audio resources
    # while a replacement client is launched.
    trap 'terminate_moonlight; exit 0' HUP INT TERM

    while kill -0 "$moonlight_pid" >/dev/null 2>&1; do
      moonlight_address="$(
        hyprctl -j clients 2>/dev/null \
          | jq -r --argjson pid "$moonlight_pid" '
              first(
                .[]
                | select(
                    .mapped
                    and .pid == $pid
                  )
                | .address
              ) // empty
            '
      )"
      if [ -n "$moonlight_address" ]; then
        # Moonlight can replace its XWayland window while the renderer is
        # initialized. Place each newly observed address, not just the first
        # transient window, or concurrent client starts can leave the final
        # window tiled on whichever workspace was focused last.
        if [ "$moonlight_address" != "$placed_moonlight_address" ]; then
          hyprctl dispatch movetoworkspacesilent \
            ${toString targetWorkspace},"address:$moonlight_address" \
            >/dev/null 2>&1 || true
          if [ "$seen_window" -eq 0 ]; then
            hyprctl dispatch workspace ${toString targetWorkspace} \
              >/dev/null 2>&1 || true
            hyprctl dispatch focuswindow "address:$moonlight_address" \
              >/dev/null 2>&1 || true
          fi
          placed_moonlight_address="$moonlight_address"
        fi
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
    trap - HUP INT TERM
  '';

  moonlightSession = pkgs.writeShellApplication {
    name = "moonlight-session";
    runtimeInputs = [
      moonlightPackage
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
    ];
    text =
      if cfg.relaunchOnExit
      then ''
        ${lib.getExe moonlightEndpointSetup}
        ${lib.getExe displayModeSetup}
        ${lib.optionalString cfg.preferHdmiAudio "${lib.getExe hdmiAudioSetup} || true"}

        while true; do
          ${moonlightInvocation} &
          moonlight_pid=$!
          ${superviseMoonlightWindow 1}
          sleep 1
        done
      ''
      else ''
        ${lib.getExe moonlightEndpointSetup}
        ${lib.getExe displayModeSetup}
        ${lib.optionalString cfg.preferHdmiAudio "${lib.getExe hdmiAudioSetup} || true"}

        ${moonlightInvocation} &
        moonlight_pid=$!
        ${superviseMoonlightWindow 1}
        exit "$status"
      '';
  };

  couchBrowser = pkgs.writeShellApplication {
    name = "couch-browser";
    runtimeInputs = [pkgs.hyprland];
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

      ${
        if cfg.enableLocalBrowser
        then "exec ${lib.getExe couchBrowser}"
        else ''
          echo "Remote browser did not become ready and the local fallback is disabled" >&2
          exit 1
        ''
      }
    '';
  };

  couchTerminal = pkgs.writeShellApplication {
    name = "couch-terminal";
    runtimeInputs = [pkgs.hyprland];
    text = ''
      hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
      exec ${lib.getExe cfg.terminalPackage}
    '';
  };

  couchFallbackBrowser = lib.optionalAttrs (cfg.fallbackBrowserPackage != null) {
    package = pkgs.writeShellApplication {
      name = "couch-browser-fallback";
      runtimeInputs = [pkgs.hyprland];
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
    runtimeInputs = [pkgs.zenity];
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
          show_status info "Starting Steam" \
            "Starting the remote Steam host. A cold start can take up to ${toString cfg.streamStartupTimeout} seconds."
          ${cfg.streamHostStartCommand}
          show_status info "Steam container started" \
            "Waiting for the streaming service to become ready."
        fi
      ''}

      ${lib.optionalString (streamReadinessHosts != []) ''
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

      ${
        if directStreamEnabled
        then ''show_status info "Steam is ready" "Connecting Moonlight now."''
        else ''show_status info "Moonlight" "Opening the host chooser."''
      }
      exec ${lib.getExe moonlightSession}
    '';
  };

  mkMoonlightBrowserSession = name: endpointSetup: invocation: targetWorkspace: application:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.hyprland
        pkgs.jq
      ];
      text = ''
        ${lib.optionalString (
            application == cfg.browserStreamApplication && cfg.browserStreamPrepareCommand != null
          )
          cfg.browserStreamPrepareCommand}
        ${lib.getExe endpointSetup}
        ${lib.getExe displayModeSetup}
        ${invocation} &
        moonlight_pid=$!
        ${lib.optionalString (cfg.browserStreamLayoutCommand != null) ''
          (
            COUCH_KEYBOARD_LAYOUT="$(${lib.getExe activeKeyboardLayout})"
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
        ${superviseMoonlightWindow targetWorkspace}
        exit "$status"
      '';
    };
  moonlightBrowserSession =
    mkMoonlightBrowserSession "moonlight-browser-session" moonlightEndpointSetup
    browserMoonlightInvocation
    2
    cfg.browserStreamApplication;
  moonlightBrowserSelectorSession =
    mkMoonlightBrowserSession "moonlight-browser-selector-session" browserSelectorEndpointSetup
    browserSelectorMoonlightInvocation
    3
    cfg.browserStreamSelectorApplication;
in {
  inherit
    couchBrowser
    couchBrowserNewWindow
    couchBrowserStartup
    couchFallbackBrowser
    couchTerminal
    moonlightBrowserSelectorSession
    moonlightBrowserSession
    moonlightSession
    moonlightStreamStart
    protectedBrowser
    protectedBrowserSession
    ;
}
