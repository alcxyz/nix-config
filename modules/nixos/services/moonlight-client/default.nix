# nix-config/modules/nixos/services/moonlight-client/default.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.moonlight-client;

  modeStateDirectory = "/var/lib/moonlight-client";
  modeStateFile = "${modeStateDirectory}/session-mode";
  directStreamEnabled = cfg.streamHost != null && cfg.streamApplication != null;
  moonlightInvocation =
    if directStreamEnabled
    then
      lib.escapeShellArgs (
        [
          (lib.getExe cfg.package)
          "stream"
        ]
        ++ cfg.streamArguments
        ++ [
          cfg.streamHost
          cfg.streamApplication
        ]
      )
    else lib.getExe cfg.package;

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
    ];
    text =
      if cfg.relaunchOnExit
      then ''
        ${lib.getExe displayModeSetup}
        ${lib.optionalString cfg.preferHdmiAudio "${lib.getExe hdmiAudioSetup} || true"}

        while true; do
          ${moonlightInvocation} || true
          sleep 1
        done
      ''
      else ''
        ${lib.getExe displayModeSetup}
        ${lib.optionalString cfg.preferHdmiAudio "${lib.getExe hdmiAudioSetup} || true"}

        status=0
        ${moonlightInvocation} || status=$?
        hyprctl dispatch exit >/dev/null 2>&1 || true
        exit "$status"
      '';
  };

  couchBrowser = pkgs.writeShellApplication {
    name = "couch-browser";
    runtimeInputs = [pkgs.hyprland];
    text = ''
      hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
      exec ${lib.getExe cfg.browserPackage} \
        --user-data-dir="$HOME/.local/share/${cfg.browserProfileDirectory}" \
        --ozone-platform=x11 \
        --start-fullscreen \
        "$@"
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
          --start-fullscreen \
          "$@"
      '';
    };
  };

  dmsSession = pkgs.writeShellApplication {
    name = "couch-dms";
    text = ''
      dms="$HOME/.nix-profile/bin/dms"
      if [ ! -x "$dms" ]; then
        echo "DMS is not installed in the user profile" >&2
        exit 1
      fi
      exec "$dms" run
    '';
  };

  sessionMode = pkgs.writeShellApplication {
    name = "xps-session-mode";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      mode_file=${lib.escapeShellArg modeStateFile}
      current="$(tr -d '[:space:]' < "$mode_file" 2>/dev/null || true)"

      if [ "$#" -eq 0 ]; then
        printf '%s\n' "''${current:-${cfg.defaultSessionMode}}"
        exit 0
      fi

      case "$1" in
        couch | desktop)
          if [ "$1" = "$current" ]; then
            printf 'XPS is already configured for %s mode\n' "$1"
            exit 0
          fi
          printf '%s\n' "$1" > "$mode_file"
          printf 'Switching XPS to %s mode\n' "$1"
          ;;
        *)
          echo "usage: xps-session-mode [couch|desktop]" >&2
          exit 2
          ;;
      esac
    '';
  };

  couchApplications = pkgs.runCommand "couch-session-applications" {} ''
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
    ''}
  '';

  hyprlandConfig = pkgs.writeText "moonlight-hyprland.conf" ''
    monitor = , ${cfg.outputMode}, auto, ${toString cfg.outputScale}
    ${lib.optionalString cfg.disableInternalDisplay ''
      monitor = eDP-1, disable
      monitor = LVDS-1, disable
    ''}

    env = QT_QPA_PLATFORM,wayland
    env = QT_QPA_PLATFORMTHEME,gtk3
    env = QT_QPA_PLATFORMTHEME_QT6,gtk3

    exec-once = [workspace 1 silent] ${lib.getExe moonlightSession}
    # Hyprland's portal does not implement RemoteDesktop. Keep KDE Connect and
    # couch browsers on XWayland so its phone keyboard and touchpad can inject
    # input through XTest instead.
    ${lib.optionalString cfg.enableKdeConnect "exec-once = ${pkgs.coreutils}/bin/env QT_QPA_PLATFORM=xcb ${lib.getExe' pkgs.kdePackages.kdeconnect-kde "kdeconnectd"}"}
    ${lib.optionalString cfg.enableDms "exec-once = ${lib.getExe dmsSession}"}

    input {
      kb_layout = us,no
      kb_options = grp:alt_shift_toggle
      numlock_by_default = true

      touchpad {
        natural_scroll = true
      }
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
    }

    cursor {
      inactive_timeout = 3
    }

    windowrule = match:class com.moonlight_stream.Moonlight, fullscreen true

    bind = SUPER, 1, workspace, 1
    bind = SUPER, 2, workspace, 2
    bind = SUPER, M, workspace, 1
    bind = SUPER, B, exec, ${lib.getExe couchBrowser}
    ${lib.optionalString cfg.enableDms "bind = SUPER, SPACE, exec, $HOME/.nix-profile/bin/dms ipc call spotlight toggle"}
    bind = SUPER, W, killactive

    # Emergency exit back to greetd if the couch session cannot be closed normally.
    bind = SUPER SHIFT, Q, exit
  '';

  sessionPackage = pkgs.writeTextFile {
    name = "moonlight-hyprland-session";
    destination = "/share/wayland-sessions/moonlight-hyprland.desktop";
    passthru.providedSessions = ["moonlight-hyprland"];
    text = ''
      [Desktop Entry]
      Name=Couch (Hyprland)
      Comment=Moonlight, browser, and phone-friendly TV session
      Exec=${pkgs.hyprland}/bin/start-hyprland -- --config ${hyprlandConfig}
      Type=Application
      DesktopNames=Hyprland
    '';
  };

  sessionCommand = "${pkgs.hyprland}/bin/start-hyprland -- --config ${hyprlandConfig}";

  sessionDispatcher = pkgs.writeShellApplication {
    name = "couch-session-dispatcher";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      mode="$(tr -d '[:space:]' < ${lib.escapeShellArg modeStateFile} 2>/dev/null || true)"
      case "$mode" in
        desktop)
          exec ${cfg.desktopSessionCommand}
          ;;
        couch | *)
          exec ${sessionCommand}
          ;;
      esac
    '';
  };
in {
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

    streamArguments = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional arguments passed to the direct Moonlight stream command.";
    };

    enableDms = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Start DMS from the user's Home Manager profile in the dedicated session.";
    };

    enableBluetoothControllerReconnect = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Continuously reconnect paired and trusted Bluetooth game controllers.";
    };

    enableKdeConnect = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable KDE Connect and start its daemon in the dedicated session.";
    };

    browserPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.helium;
      defaultText = lib.literalExpression "pkgs.helium";
      description = "Browser package used by the couch browser launcher.";
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

    desktopSessionCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Command for the normal desktop session, or null to disable persistent mode switching.";
    };

    defaultSessionMode = lib.mkOption {
      type = lib.types.enum ["couch" "desktop"];
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
    environment.systemPackages =
      [
        cfg.package
        cfg.browserPackage
        couchBrowser
        couchApplications
      ]
      ++ lib.optional (cfg.fallbackBrowserPackage != null) cfg.fallbackBrowserPackage
      ++ lib.optional (cfg.fallbackBrowserPackage != null) couchFallbackBrowser.package
      ++ lib.optional (cfg.desktopSessionCommand != null) sessionMode;
    services.displayManager.sessionPackages = [sessionPackage];

    # Install udev rules for common controllers, including Steam hardware.
    hardware.steam-hardware.enable = true;

    programs.kdeconnect.enable = cfg.enableKdeConnect;

    systemd.services.moonlight-controller-reconnect = lib.mkIf cfg.enableBluetoothControllerReconnect {
      description = "Reconnect trusted Bluetooth game controllers";
      after = ["bluetooth.service"];
      wants = ["bluetooth.service"];
      wantedBy = ["multi-user.target"];
      path = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.systemd
      ];
      serviceConfig = {
        Restart = "always";
        RestartSec = "5s";
      };
      script = ''
        prop() {
          busctl get-property org.bluez "$1" org.bluez.Device1 "$2" 2>/dev/null || true
        }

        while true; do
          while read -r device; do
            [ "$(prop "$device" Icon)" = 's "input-gaming"' ] || continue
            [ "$(prop "$device" Paired)" = "b true" ] || continue
            [ "$(prop "$device" Trusted)" = "b true" ] || continue
            [ "$(prop "$device" Connected)" = "b false" ] || continue

            busctl --timeout=5s call \
              org.bluez "$device" org.bluez.Device1 Connect \
              >/dev/null 2>&1 || true
          done < <(
            busctl tree --list org.bluez \
              | grep -E '^/org/bluez/hci[0-9]+/dev_[^/]+$' \
              || true
          )

          sleep 5
        done
      '';
    };

    services.greetd.settings.initial_session = lib.mkIf (cfg.autoLoginUser != null) {
      command =
        if cfg.desktopSessionCommand == null
        then sessionCommand
        else lib.getExe sessionDispatcher;
      user = cfg.autoLoginUser;
    };

    systemd.tmpfiles.rules = lib.optional (cfg.autoLoginUser != null && cfg.desktopSessionCommand != null) "d ${modeStateDirectory} 0755 ${cfg.autoLoginUser} root - -" ++ lib.optional (cfg.autoLoginUser != null && cfg.desktopSessionCommand != null) "f ${modeStateFile} 0644 ${cfg.autoLoginUser} root - ${cfg.defaultSessionMode}";

    systemd.paths.couch-session-mode-switch = lib.mkIf (cfg.autoLoginUser != null && cfg.desktopSessionCommand != null) {
      description = "Watch for XPS couch/desktop session mode changes";
      wantedBy = ["multi-user.target"];
      pathConfig = {
        PathChanged = modeStateFile;
        Unit = "couch-session-mode-switch.service";
      };
    };

    systemd.services.couch-session-mode-switch = lib.mkIf (cfg.autoLoginUser != null && cfg.desktopSessionCommand != null) {
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
        assertion = (cfg.streamHost == null) == (cfg.streamApplication == null);
        message = "services.moonlight-client.streamHost and streamApplication must be set together";
      }
    ];
  };
}
