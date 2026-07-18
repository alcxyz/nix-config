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
  runtimeStateDirectory = "/run/moonlight-client";
  dynamicMonitorConfigFile = "${runtimeStateDirectory}/monitors.conf";
  mergedDmsConfigDirectory = "${runtimeStateDirectory}/dms-merged";
  mergedDmsSettingsFile = pkgs.writeText "dms-merged-settings.json" (
    builtins.toJSON cfg.mergedDmsSettings
  );
  directStreamEnabled = cfg.streamHost != null && cfg.streamApplication != null;
  defaultOutputMode =
    if cfg.autoMirrorExternalOutputs
    then cfg.autoMirrorSecondaryMode
    else cfg.outputMode;
  mirrorOutputMode =
    if cfg.mirrorOutputMode == null
    then cfg.outputMode
    else cfg.mirrorOutputMode;
  mirrorSourceOutputs = lib.unique (lib.attrValues cfg.mirrorOutputs);
  moonlightInvocation =
    if directStreamEnabled
    then
      lib.escapeShellArgs (
        [
          "${pkgs.coreutils}/bin/env"
          "QT_QPA_PLATFORM=${cfg.moonlightPlatform}"
          (lib.getExe cfg.package)
          "stream"
        ]
        ++ cfg.streamArguments
        ++ [
          cfg.streamHost
          cfg.streamApplication
        ]
      )
    else
      lib.escapeShellArgs [
        "${pkgs.coreutils}/bin/env"
        "QT_QPA_PLATFORM=${cfg.moonlightPlatform}"
        (lib.getExe cfg.package)
      ];

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
      if cfg.relaunchOnExit
      then ''
        ${lib.getExe displayModeSetup}
        ${lib.optionalString cfg.preferHdmiAudio "${lib.getExe hdmiAudioSetup} || true"}

        while true; do
          # Moonlight is a child of this launcher, so Hyprland's exec-once
          # workspace rule does not apply when the stream process is relaunched.
          hyprctl dispatch workspace 1 >/dev/null 2>&1 || true
          ${moonlightInvocation} &
          moonlight_pid=$!
          seen_window=0
          missing_window_checks=0

          while kill -0 "$moonlight_pid" >/dev/null 2>&1; do
            if hyprctl -j clients 2>/dev/null \
              | jq -e 'any(.[]; .class == "com.moonlight_stream.Moonlight" and .mapped)' \
                >/dev/null 2>&1; then
              seen_window=1
              missing_window_checks=0
            elif [ "$seen_window" -eq 1 ]; then
              missing_window_checks=$((missing_window_checks + 1))
              if [ "$missing_window_checks" -ge 5 ]; then
                kill "$moonlight_pid" >/dev/null 2>&1 || true
                sleep 1
                kill -KILL "$moonlight_pid" >/dev/null 2>&1 || true
                break
              fi
            fi
            sleep 2
          done

          wait "$moonlight_pid" || true
          sleep 1
        done
      ''
      else ''
        ${lib.getExe displayModeSetup}
        ${lib.optionalString cfg.preferHdmiAudio "${lib.getExe hdmiAudioSetup} || true"}

        hyprctl dispatch workspace 1 >/dev/null 2>&1 || true
        status=0
        ${moonlightInvocation} || status=$?
        hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
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
        --start-fullscreen \
        "$@"
    '';
  };

  couchBrowserNewWindow = pkgs.writeShellApplication {
    name = "couch-browser-new-window";
    text = ''
      exec ${lib.getExe couchBrowser} --new-window "$@"
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
          --start-fullscreen \
          "$@"
      '';
    };
  };

  moonlightStreamStart = pkgs.writeShellApplication {
    name = "couch-moonlight-start";
    runtimeInputs = [
      pkgs.netcat-openbsd
    ];
    text = ''
      host_ready=0
      ${lib.optionalString (cfg.streamReadinessHost != null) ''
        if nc -z -w 1 ${lib.escapeShellArg cfg.streamReadinessHost} ${toString cfg.streamReadinessPort} \
          >/dev/null 2>&1; then
          host_ready=1
        fi
      ''}

      ${lib.optionalString (cfg.streamHostStartCommand != null) ''
        if [ "$host_ready" -eq 0 ]; then
          ${cfg.streamHostStartCommand}
        fi
      ''}

      ${lib.optionalString (cfg.streamReadinessHost != null) ''
        host_ready=0
        for ((attempt = 0; attempt < ${toString cfg.streamStartupTimeout}; attempt++)); do
          if nc -z -w 1 ${lib.escapeShellArg cfg.streamReadinessHost} ${toString cfg.streamReadinessPort} \
            >/dev/null 2>&1; then
            host_ready=1
            break
          fi
          sleep 1
        done

        if [ "$host_ready" -eq 0 ]; then
          echo "stream host did not become ready" >&2
          exit 1
        fi
      ''}

      exec ${lib.getExe moonlightSession}
    '';
  };

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
          systemctl --user start couch-moonlight-stream.service
          ;;
        browser)
          systemctl --user stop couch-moonlight-stream.service >/dev/null 2>&1 || true
          ${lib.getExe mergedUiControl} browser
          hyprctl dispatch workspace 2 >/dev/null 2>&1 || true

          if ! pgrep -u "$USER" -f -- ${lib.escapeShellArg cfg.browserProfileDirectory} \
            >/dev/null 2>&1; then
            ${lib.getExe couchBrowser} >/dev/null 2>&1 &
          fi
          ;;
        *)
          echo "usage: couch-stream-control {start|browser}" >&2
          exit 2
          ;;
      esac
    '';
  };

  controllerPython = pkgs.python3.withPackages (pythonPackages: [pythonPackages.evdev]);
  controllerDaemonSource = pkgs.writeText "couch-controller.py" ''
    import select
    import subprocess
    import time

    from evdev import InputDevice, ecodes, list_devices


    DEVICE_NAME = ${builtins.toJSON cfg.controllerDeviceName}
    HOLD_SECONDS = ${toString cfg.controllerHoldSeconds}
    ACTIONS = {
        "start": {ecodes.BTN_MODE, ecodes.BTN_EAST},
        "browser": {ecodes.BTN_THUMBL, ecodes.BTN_THUMBR},
    }
    COMMANDS = {
        "start": [${builtins.toJSON (lib.getExe couchStreamControl)}, "start"],
        "browser": [${builtins.toJSON (lib.getExe couchStreamControl)}, "browser"],
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

  pointerSyncSource = pkgs.writeText "couch-pointer-sync.py" ''
    import ctypes
    import subprocess
    import time


    x11 = ctypes.CDLL(${builtins.toJSON "${pkgs.libx11}/lib/libX11.so.6"})
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x11.XDefaultRootWindow.restype = ctypes.c_ulong
    x11.XQueryPointer.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ulong,
        ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_uint),
    ]
    x11.XQueryPointer.restype = ctypes.c_int


    display = None
    while not display:
        display = x11.XOpenDisplay(b":0")
        if not display:
            time.sleep(0.5)

    root = x11.XDefaultRootWindow(display)
    last_position = None

    while True:
        root_return = ctypes.c_ulong()
        child_return = ctypes.c_ulong()
        root_x = ctypes.c_int()
        root_y = ctypes.c_int()
        window_x = ctypes.c_int()
        window_y = ctypes.c_int()
        mask = ctypes.c_uint()

        if x11.XQueryPointer(
            display,
            root,
            ctypes.byref(root_return),
            ctypes.byref(child_return),
            ctypes.byref(root_x),
            ctypes.byref(root_y),
            ctypes.byref(window_x),
            ctypes.byref(window_y),
            ctypes.byref(mask),
        ):
            position = (root_x.value, root_y.value)
            if position != last_position:
                subprocess.run(
                    [
                        ${builtins.toJSON (lib.getExe' pkgs.hyprland "hyprctl")},
                        "dispatch",
                        "movecursor",
                        str(position[0]),
                        str(position[1]),
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                )
                last_position = position

        time.sleep(1 / 60)
  '';

  pointerSync = pkgs.writeShellApplication {
    name = "couch-pointer-sync";
    text = ''
      exec ${pkgs.python3}/bin/python ${pointerSyncSource}
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

  autoMirrorExternalOutputs = pkgs.writeShellApplication {
    name = "couch-auto-mirror-outputs";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
      pkgs.wl-mirror
    ];
    text = ''
      config_file=${lib.escapeShellArg dynamicMonitorConfigFile}
      layout_key=""
      mirror_pid=""

      stop_mirror() {
        if [ -n "$mirror_pid" ] && kill -0 "$mirror_pid" 2>/dev/null; then
          kill "$mirror_pid" 2>/dev/null || true
          wait "$mirror_pid" 2>/dev/null || true
        fi
        mirror_pid=""
      }

      write_layout() {
        source_output="$1"
        target_output="$2"
        temporary_file="$config_file.tmp"

        {
          if [ -n "$source_output" ]; then
            printf 'monitor = %s, %s, 0x0, %s\n' \
              "$source_output" \
              ${lib.escapeShellArg cfg.outputMode} \
              ${lib.escapeShellArg (toString cfg.outputScale)}
            printf 'workspace = 1, monitor:%s, default:true\n' "$source_output"
            printf 'workspace = 2, monitor:%s\n' "$source_output"
          fi
          if [ -n "$target_output" ]; then
            printf 'monitor = %s, %s, %s, %s\n' \
              "$target_output" \
              ${lib.escapeShellArg cfg.autoMirrorSecondaryMode} \
              ${lib.escapeShellArg cfg.autoMirrorSecondaryPosition} \
              ${lib.escapeShellArg (toString cfg.autoMirrorSecondaryScale)}
            printf 'workspace = %s, monitor:%s, default:true\n' \
              ${lib.escapeShellArg (toString cfg.autoMirrorWorkspace)} \
              "$target_output"
          fi
        } >"$temporary_file"

        if ! cmp -s "$temporary_file" "$config_file"; then
          mv "$temporary_file" "$config_file"
          hyprctl reload >/dev/null 2>&1 || true
          sleep 0.5
        else
          rm -f "$temporary_file"
        fi

        if [ -n "$source_output" ]; then
          hyprctl dispatch moveworkspacetomonitor 1 "$source_output" >/dev/null 2>&1 || true
          hyprctl dispatch moveworkspacetomonitor 2 "$source_output" >/dev/null 2>&1 || true
        fi
        if [ -n "$target_output" ]; then
          # Workspace rules do not create an absent workspace. Activate the
          # dedicated workspace once so wl-mirror cannot inherit whichever
          # workspace happened to be visible during compositor startup.
          hyprctl dispatch focusmonitor "$target_output" >/dev/null 2>&1 || true
          hyprctl dispatch workspace \
            ${lib.escapeShellArg (toString cfg.autoMirrorWorkspace)} \
            >/dev/null 2>&1 || true
          hyprctl dispatch moveworkspacetomonitor \
            ${lib.escapeShellArg (toString cfg.autoMirrorWorkspace)} \
            "$target_output" \
            >/dev/null 2>&1 || true
        fi
        if [ -n "$source_output" ]; then
          hyprctl dispatch focusmonitor "$source_output" >/dev/null 2>&1 || true
          hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
        fi
      }

      trap stop_mirror EXIT INT TERM

      while true; do
        monitors="$(hyprctl -j monitors all 2>/dev/null || printf '[]')"
        external_monitors="$(
          jq -c '[.[] | select(
            .name != "eDP-1" and .name != "LVDS-1" and .disabled == false
          )]' <<<"$monitors" 2>/dev/null || printf '[]'
        )"
        source_output="$(
          jq -r --argjson minimum_width ${lib.escapeShellArg (toString cfg.autoMirrorPrimaryMinPhysicalWidth)} '
            if length == 0 then ""
            else
              max_by(.physicalWidth * .physicalHeight)
              | if .physicalWidth >= $minimum_width then .name else "" end
            end
          ' <<<"$external_monitors"
        )"
        target_output=""
        if [ -n "$source_output" ]; then
          target_output="$(
            jq -r --arg source "$source_output" '
              [.[] | select(.name != $source)]
              | if length == 0 then ""
                else min_by(.physicalWidth * .physicalHeight).name end
            ' <<<"$external_monitors"
          )"
        fi

        new_layout_key="$source_output:$target_output"
        if [ "$new_layout_key" != "$layout_key" ]; then
          stop_mirror
          write_layout "$source_output" "$target_output"
          layout_key="$new_layout_key"
        fi

        if [ -n "$source_output" ] && [ -n "$target_output" ] \
          && { [ -z "$mirror_pid" ] || ! kill -0 "$mirror_pid" 2>/dev/null; }; then
          hyprctl dispatch focusmonitor "$target_output" >/dev/null 2>&1 || true
          hyprctl dispatch workspace \
            ${lib.escapeShellArg (toString cfg.autoMirrorWorkspace)} \
            >/dev/null 2>&1 || true
          wl-mirror \
            --fullscreen-output "$target_output" \
            --scaling fit \
            --title "Couch mirror $source_output" \
            "$source_output" &
          mirror_pid=$!
          sleep 0.5
          hyprctl dispatch focusmonitor "$source_output" >/dev/null 2>&1 || true
          hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
        fi

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
      exec "$dms" run
    '';
  };

  mergedDmsSession = pkgs.writeShellApplication {
    name = "couch-merged-dms";
    runtimeInputs = [pkgs.coreutils];
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

      config_home=${lib.escapeShellArg mergedDmsConfigDirectory}
      settings_directory="$config_home/DankMaterialShell"
      rm -rf "$config_home"
      install -d -m 0700 "$settings_directory"
      install -m 0600 ${mergedDmsSettingsFile} "$settings_directory/settings.json"

      plugin_settings="$HOME/.config/DankMaterialShell/plugin_settings.json"
      if [ -e "$plugin_settings" ]; then
        ln -s "$plugin_settings" "$settings_directory/plugin_settings.json"
      fi

      export XDG_CONFIG_HOME="$config_home"
      exec "$dms" run
    '';
  };

  mergedUiControl = pkgs.writeShellApplication {
    name = "couch-merged-ui";
    runtimeInputs = [pkgs.coreutils];
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
    runtimeInputs = [pkgs.coreutils];
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
      output:
        "monitor = ${output}, ${mirrorOutputMode}, 0x0, ${toString cfg.outputScale}"
    )
    mirrorSourceOutputs}
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        output: source:
          "monitor = ${output}, ${mirrorOutputMode}, 0x0, ${toString cfg.outputScale}, mirror, ${source}"
      )
      cfg.mirrorOutputs
    )}
    ${lib.concatStringsSep "\n" (map (rule: "monitor = ${rule}") cfg.extraMonitorRules)}
    ${lib.concatStringsSep "\n" (map (rule: "workspace = ${rule}") cfg.extraWorkspaceRules)}
    ${lib.optionalString cfg.autoMirrorExternalOutputs "source = ${dynamicMonitorConfigFile}"}
    ${lib.optionalString cfg.disableInternalDisplay ''
      monitor = eDP-1, disable
      monitor = LVDS-1, disable
    ''}

    env = QT_QPA_PLATFORM,wayland
    env = QT_QPA_PLATFORMTHEME,gtk3
    env = QT_QPA_PLATFORMTHEME_QT6,gtk3

    exec-once = ${pkgs.systemd}/bin/systemctl --user import-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP DBUS_SESSION_BUS_ADDRESS
    ${lib.optionalString cfg.autoMirrorExternalOutputs "exec-once = ${lib.getExe autoMirrorExternalOutputs}"}
    ${lib.optionalString cfg.autoStartBrowser "exec-once = ${lib.getExe couchBrowser}"}
    ${lib.optionalString cfg.autoStartStream "exec-once = [workspace 1 silent] ${lib.getExe moonlightSession}"}
    ${lib.optionalString cfg.enableControllerShortcuts "exec-once = ${lib.getExe controllerDaemon}"}
    # Hyprland's portal does not implement RemoteDesktop. Keep KDE Connect and
    # couch browsers on XWayland so its phone keyboard and touchpad can inject
    # input through XTest instead.
    ${lib.optionalString cfg.enableKdeConnect "exec-once = ${pkgs.coreutils}/bin/env QT_QPA_PLATFORM=xcb ${lib.getExe' pkgs.kdePackages.kdeconnect-kde "kdeconnectd"}"}
    ${lib.optionalString cfg.enableKdeConnect "exec-once = ${lib.getExe pointerSync}"}
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        output: source:
          "exec-once = ${lib.getExe softwareMirror} ${lib.escapeShellArg output} ${lib.escapeShellArg source}"
      )
      cfg.softwareMirrorOutputs
    )}
    ${lib.optionalString cfg.enableDms "exec-once = ${lib.getExe dmsSession}"}
    ${lib.optionalString cfg.enableMergedProfile "exec-once = ${lib.getExe mergedDmsSession}"}

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
    windowrule = match:class CouchBrowser, workspace 2
    windowrule = match:class CouchBrowser, fullscreen true

    bind = SUPER, 1, workspace, 1
    bind = SUPER, 2, workspace, 2
    ${
      if cfg.enableControllerShortcuts
      then "bind = SUPER, M, exec, ${lib.getExe couchStreamControl} start"
      else "bind = SUPER, M, workspace, 1"
    }
    bind = SUPER, B, exec, ${lib.getExe couchStreamControl} browser
    bind = SUPER, V, exec, ${lib.getExe couchBrowserNewWindow}
    bind = ALT, RETURN, exec, ${lib.getExe couchTerminal}
    ${lib.optionalString (cfg.enableDms || cfg.enableMergedProfile) "bind = SUPER, SPACE, exec, $HOME/.nix-profile/bin/dms ipc call spotlight toggle"}
    bind = SUPER, W, killactive
    bind = SUPER, RETURN, fullscreen
    bind = SUPER, S, togglefloating

    bind = SUPER, J, workspace, r-1
    bind = SUPER, K, workspace, r+1
    bind = SUPER, down, workspace, r-1
    bind = SUPER, up, workspace, r+1
    bind = SUPER, TAB, workspace, previous

    bind = SUPER SHIFT, J, movetoworkspace, r-1
    bind = SUPER SHIFT, K, movetoworkspace, r+1
    bind = SUPER SHIFT, down, movetoworkspace, r-1
    bind = SUPER SHIFT, up, movetoworkspace, r+1

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

    moonlightPlatform = lib.mkOption {
      type = lib.types.enum ["wayland" "xcb"];
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

    streamArguments = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
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
            screenPreferences = ["all"];
            showOnLastDisplay = true;
            leftWidgets = ["launcherButton" "workspaceSwitcher" "focusedWindow"];
            centerWidgets = ["music" "clock"];
            rightWidgets = ["systemTray" "notificationButton" "battery" "controlCenterButton"];
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

    browserPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.helium;
      defaultText = lib.literalExpression "pkgs.helium";
      description = "Browser package used by the couch browser launcher.";
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

    desktopSessionCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Command for the normal desktop session, or null to disable persistent mode switching.";
    };

    defaultSessionMode = lib.mkOption {
      type = lib.types.enum ["couch" "desktop" "merged"];
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
      default = {};
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
      default = [];
      example = ["DP-2, 3840x2160@60, 2560x0, 2"];
      description = "Additional Hyprland monitor rule bodies applied after the default and native mirror rules.";
    };

    extraWorkspaceRules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["10, monitor:DP-2, default:true"];
      description = "Additional Hyprland workspace rule bodies for fixed multi-output couch layouts.";
    };

    softwareMirrorOutputs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {
        "DP-2" = "DP-1";
      };
      description = "Outputs mirrored in a supervised fullscreen wl-mirror client, expressed as target-to-source mappings.";
    };

    autoMirrorExternalOutputs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Discover a physically large primary external output and supervise a software mirror on a secondary output across connector renames.";
    };

    autoMirrorSecondaryMode = lib.mkOption {
      type = lib.types.str;
      default = "1920x1080@60";
      description = "Stable mode used by the automatically discovered software-mirror target and by unmatched external outputs.";
    };

    autoMirrorSecondaryPosition = lib.mkOption {
      type = lib.types.str;
      default = "2560x0";
      description = "Hyprland position used by the automatically discovered software-mirror target.";
    };

    autoMirrorSecondaryScale = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = "Hyprland scale used by the automatically discovered software-mirror target.";
    };

    autoMirrorPrimaryMinPhysicalWidth = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1000;
      description = "Minimum reported physical width in millimetres for an external output to become the automatic mirror source.";
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
    environment.systemPackages =
      [
        cfg.package
        cfg.browserPackage
        cfg.terminalPackage
        couchBrowser
        couchBrowserNewWindow
        couchTerminal
        couchApplications
        couchStreamControl
        moonlightStreamStart
      ]
      ++ lib.optional cfg.enableControllerShortcuts controllerDaemon
      ++ lib.optional cfg.enableKdeConnect pointerSync
      ++ lib.optional cfg.enableMergedProfile mergedDmsSession
      ++ lib.optional cfg.enableMergedProfile mergedUiControl
      ++ lib.optional (cfg.softwareMirrorOutputs != {}) softwareMirror
      ++ lib.optional cfg.autoMirrorExternalOutputs autoMirrorExternalOutputs
      ++ lib.optional (cfg.fallbackBrowserPackage != null) cfg.fallbackBrowserPackage
      ++ lib.optional (cfg.fallbackBrowserPackage != null) couchFallbackBrowser.package
      ++ lib.optional (cfg.desktopSessionCommand != null) sessionMode;
    services.displayManager.sessionPackages = [sessionPackage];

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

    services.greetd.settings.initial_session = lib.mkIf (cfg.autoLoginUser != null) {
      command =
        if cfg.desktopSessionCommand == null
        then sessionCommand
        else lib.getExe sessionDispatcher;
      user = cfg.autoLoginUser;
    };

    systemd.tmpfiles.rules =
      lib.optional (cfg.autoLoginUser != null && cfg.desktopSessionCommand != null) "d ${modeStateDirectory} 0755 ${cfg.autoLoginUser} root - -"
      ++ lib.optional (cfg.autoLoginUser != null && cfg.desktopSessionCommand != null) "f ${modeStateFile} 0644 ${cfg.autoLoginUser} root - ${cfg.defaultSessionMode}"
      ++ lib.optional (cfg.autoLoginUser != null && cfg.autoMirrorExternalOutputs) "d ${runtimeStateDirectory} 0755 ${cfg.autoLoginUser} root - -"
      ++ lib.optional (cfg.autoLoginUser != null && cfg.autoMirrorExternalOutputs) "f ${dynamicMonitorConfigFile} 0644 ${cfg.autoLoginUser} root -";

    systemd.paths.couch-session-mode-switch = lib.mkIf (cfg.autoLoginUser != null && cfg.desktopSessionCommand != null) {
      description = "Watch for XPS session mode changes";
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
        assertion = cfg.defaultSessionMode != "merged" || cfg.enableMergedProfile;
        message = "services.moonlight-client.defaultSessionMode = merged requires enableMergedProfile";
      }
      {
        assertion = (cfg.streamHost == null) == (cfg.streamApplication == null);
        message = "services.moonlight-client.streamHost and streamApplication must be set together";
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
        assertion = lib.all (output: output != cfg.mirrorOutputs.${output}) (lib.attrNames cfg.mirrorOutputs);
        message = "services.moonlight-client.mirrorOutputs cannot mirror an output to itself";
      }
      {
        assertion = lib.all (output: output != cfg.softwareMirrorOutputs.${output}) (lib.attrNames cfg.softwareMirrorOutputs);
        message = "services.moonlight-client.softwareMirrorOutputs cannot mirror an output to itself";
      }
      {
        assertion = !cfg.autoMirrorExternalOutputs || cfg.autoLoginUser != null;
        message = "services.moonlight-client.autoMirrorExternalOutputs requires autoLoginUser";
      }
    ];
  };
}
