{
  activeKeyboardLayout,
  audioOutputControl,
  browserSelectorEnabled,
  cfg,
  directDrmBrowserEnabled,
  directDrmKeyboardLayoutFile,
  directDrmKmsConfigFile,
  directDrmOutputSnapshot,
  directDrmReturnModeFile,
  directDrmStreamEnabled,
  displayLayoutControl,
  displayMirrorToggle,
  lib,
  mergedDmsCheatsheetFile,
  mergedDmsConfigDirectory,
  mergedDmsSettingsFile,
  modeStateFile,
  persistentDirectDrmBrowserDefault,
  pkgs,
}: let
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
    runtimeInputs = [pkgs.gnugrep];
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
    runtimeInputs = [waitForStableOutputs];
    text = ''
      couch-wait-for-stable-outputs
      # The compositor can render before a dock-connected TV has completed its
      # physical link recovery. Retained XPS boot timings put that gap at about
      # three seconds; keep the overlay loaded but do not consume its animation
      # clock during that interval.
      export NIXBOX_SPLASH_SETTLE_MS=3000
      exec ${
        if cfg.sessionSplashCommand == null
        then "${pkgs.coreutils}/bin/true"
        else cfg.sessionSplashCommand
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
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      mode="$(tr -d '[:space:]' < ${lib.escapeShellArg modeStateFile} 2>/dev/null || true)"
      if [ "$mode" != merged ]; then
        exit 0
      fi

      dms="$HOME/.nix-profile/bin/dms"
      if [ ! -x "$dms" ]; then
        exit 0
      fi

      # DMS is presentation, not part of the stream lifecycle.  A wedged IPC
      # request must never hold a Moonlight unit in stop-post until systemd
      # marks the otherwise cleanly stopped stream as failed.
      dms_call() {
        timeout \
          --foreground \
          --signal=TERM \
          --kill-after=0.25 \
          0.5 \
          "$dms" ipc call "$@" \
          >/dev/null 2>&1
      }

      case "''${1:-}" in
        refresh)
          for unit in \
            couch-moonlight-stream.service \
            couch-moonlight-browser-stream.service \
            couch-moonlight-browser-selector.service; do
            if systemctl --user --quiet is-active "$unit"; then
              exec "$0" game
            fi
          done
          exec "$0" browser
          ;;
        game)
          dms_call notifications enableDoNotDisturbIndefinitely || true
          dms_call notifications dismissAllPopups || true
          dms_call bar hide index 0 || true
          dms_call dock hide || true
          ;;
        browser)
          for ((attempt = 0; attempt < 2; attempt++)); do
            if dms_call bar reveal index 0; then
              break
            fi
            sleep 0.1
          done
          dms_call bar autoHide index 0 || true
          dms_call dock reveal || true
          dms_call dock autoHide || true
          dms_call notifications disableDoNotDisturb || true
          ;;
        *)
          echo "usage: couch-merged-ui {refresh|game|browser}" >&2
          exit 2
          ;;
      esac
    '';
  };

  sessionMode = pkgs.writeShellApplication {
    name = "nixbox-mode";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.procps
      pkgs.systemd
      activeKeyboardLayout
    ];
    text = ''
      mode_file=${lib.escapeShellArg modeStateFile}
      persist_state() {
        state_file="$1"
        state_value="$2"
        state_tmp="$(mktemp "$state_file.XXXXXX")"
        printf '%s\n' "$state_value" > "$state_tmp"
        chmod 0644 "$state_tmp"
        mv -f "$state_tmp" "$state_file"
      }
      current="$(tr -d '[:space:]' < "$mode_file" 2>/dev/null || true)"
      current_mode="''${current%%:*}"
      supported_modes="couch${
        lib.optionalString (cfg.desktopSessionCommand != null) "|desktop"
      }${lib.optionalString cfg.enableMergedProfile "|merged"}${lib.optionalString directDrmStreamEnabled "|direct-stream"}${lib.optionalString directDrmBrowserEnabled "|direct-browser"}${
        lib.optionalString (directDrmBrowserEnabled && browserSelectorEnabled) "|direct-private"
      }"

      if [ "$#" -eq 0 ]; then
        printf '%s\n' "''${current_mode:-${cfg.defaultSessionMode}}"
        exit 0
      fi

      case "$1" in
        couch${
        lib.optionalString (cfg.desktopSessionCommand != null) " | desktop"
      }${lib.optionalString cfg.enableMergedProfile " | merged"})
          if [ "$1" = "$current_mode" ]; then
            printf 'Nixbox is already configured for %s mode\n' "$1"
            exit 0
          fi
          persist_state "$mode_file" "$1"
          ${lib.optionalString persistentDirectDrmBrowserDefault ''
        case "$current_mode" in
          direct-*)
            # Moonlight's EGLFS process ignores the graceful signal from
            # greetd. End only this user's local client after persisting
            # the explicit recovery mode so the wrapper cannot overwrite it.
            pkill -KILL -x moonlight >/dev/null 2>&1 || true
            ;;
        esac
      ''}
          printf 'Switching Nixbox to %s mode\n' "$1"
          ;;
        ${lib.optionalString (directDrmStreamEnabled || directDrmBrowserEnabled) ''
        ${lib.optionalString directDrmStreamEnabled "direct-stream"}${
          lib.optionalString (directDrmStreamEnabled && directDrmBrowserEnabled) " | "
        }${lib.optionalString directDrmBrowserEnabled "direct-browser"}${
          lib.optionalString (directDrmBrowserEnabled && browserSelectorEnabled) " | direct-private"
        })
          case "$current_mode" in
            couch${
          lib.optionalString (cfg.desktopSessionCommand != null) " | desktop"
        }${lib.optionalString cfg.enableMergedProfile " | merged"})
              return_mode="$current_mode"
              ${lib.getExe activeKeyboardLayout} \
                > ${lib.escapeShellArg directDrmKeyboardLayoutFile}
              ${lib.optionalString cfg.directDrmAutoSelectOutput ''
          ${lib.getExe directDrmOutputSnapshot}
        ''}
              ;;
            direct-*)
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
          lib.optionalString persistentDirectDrmBrowserDefault " | direct-browser"
        }) ;;
                *) return_mode=${lib.escapeShellArg cfg.defaultSessionMode} ;;
              esac
              ${lib.optionalString cfg.directDrmAutoSelectOutput ''
          if [ ! -s ${lib.escapeShellArg directDrmKmsConfigFile} ]; then
            echo "No saved direct DRM output is available" >&2
            exit 1
          fi
        ''}
              ;;
            *)
              return_mode=${lib.escapeShellArg cfg.defaultSessionMode}
              ${lib.getExe activeKeyboardLayout} \
                > ${lib.escapeShellArg directDrmKeyboardLayoutFile}
              ${lib.optionalString cfg.directDrmAutoSelectOutput ''
          ${lib.getExe directDrmOutputSnapshot}
        ''}
              ;;
          esac
          persist_state ${lib.escapeShellArg directDrmReturnModeFile} "$return_mode"
            # Stop compositor clients while their Wayland/XWayland connections
            # are still valid. Letting greetd tear them down first can leave
            # otherwise expected disconnects recorded as failed user units.
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
          boot_id="$(tr -d '[:space:]' < /proc/sys/kernel/random/boot_id)"
          persist_state "$mode_file" "$1:$boot_id"
          printf 'Switching Nixbox to %s mode\n' "$1"
          ;;
      ''}
        *)
          echo "usage: nixbox-mode [$supported_modes]" >&2
          exit 2
          ;;
      esac
    '';
  };
in {
  inherit
    dmsSession
    mergedDmsCondition
    mergedDmsServiceControl
    mergedDmsSession
    mergedUiControl
    sessionMode
    sessionPowerAction
    sessionSplashLaunch
    waitForStableOutputs
    ;
}
