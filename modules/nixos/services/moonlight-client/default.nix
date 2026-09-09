# nix-config/modules/nixos/services/moonlight-client/default.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.moonlight-client;
  kdeConnectInputDefaults = import ../../../shared/kdeconnect-input.nix;
  kdeConnectExecutable = lib.getExe' pkgs.kdePackages.kdeconnect-kde "kdeconnectd";
  kdeConnectHyprlandInput =
    pkgs.callPackage ../kdeconnect-hyprland-input {};
  moonlightPackage = cfg.package.overrideAttrs (old: {
    patches =
      (old.patches or [])
      ++ [
        ./patches/poll-absolute-mouse.patch
        ./patches/forward-media-keys.patch
      ];
  });

  modeStateDirectory = "/var/lib/moonlight-client";
  modeStateFile = "${modeStateDirectory}/session-mode";
  directDrmReturnModeFile = "${modeStateDirectory}/direct-drm-return-mode";
  directDrmKeyboardLayoutFile = "${modeStateDirectory}/direct-drm-keyboard-layout";
  directDrmKmsConfigFile = "${modeStateDirectory}/direct-drm-kms.json";
  qtConnectorName = connector:
    lib.replaceStrings
    [
      "HDMI-A-"
      "HDMI-B-"
      "-"
    ]
    [
      "HDMI"
      "HDMI"
      ""
    ]
    connector;
  directDrmFixedKmsConfigFile =
    if cfg.directDrmFixedOutput == null
    then null
    else
      pkgs.writeText "moonlight-direct-drm-fixed-kms.json" (
        builtins.toJSON {
          device = cfg.directDrmFixedOutput.device;
          outputs =
            [
              {
                name = qtConnectorName cfg.directDrmFixedOutput.connector;
                mode = cfg.directDrmFixedOutput.mode;
                primary = true;
                virtualIndex = 0;
              }
            ]
            ++ map
            (connector: {
              name = qtConnectorName connector;
              mode = "off";
            })
            cfg.directDrmFixedOutput.disabledConnectors;
        }
      );
  directDrmKmsConfigEnabled =
    cfg.directDrmAutoSelectOutput || cfg.directDrmFixedOutput != null;
  directDrmActiveKmsConfigFile =
    if cfg.directDrmAutoSelectOutput
    then directDrmKmsConfigFile
    else directDrmFixedKmsConfigFile;
  runtimeStateDirectory = "/run/moonlight-client";
  dynamicMonitorConfigFile = "${runtimeStateDirectory}/monitors.conf";
  mirrorStateFile = "${modeStateDirectory}/mirror-enabled";
  displayLayoutStateFile = "${modeStateDirectory}/display-layout";
  mergedDmsConfigDirectory = "${runtimeStateDirectory}/dms-merged";
  effectiveMergedDmsSettings =
    lib.recursiveUpdate (
      lib.optionalAttrs
      (cfg.sessionSplashCommand != null)
      {
        customPowerActionReboot = "${lib.getExe sessionPowerAction} reboot";
        customPowerActionPowerOff = "${lib.getExe sessionPowerAction} poweroff";
      }
    )
    cfg.mergedDmsSettings;
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
  browserSelectorHost =
    if cfg.browserStreamSelectorHost == null
    then cfg.browserStreamHost
    else cfg.browserStreamSelectorHost;
  browserSelectorLocalAddress =
    if cfg.browserStreamSelectorLocalAddress == null
    then cfg.browserStreamLocalAddress
    else cfg.browserStreamSelectorLocalAddress;
  browserSelectorRemoteAddress =
    if cfg.browserStreamSelectorRemoteAddress == null
    then cfg.browserStreamRemoteAddress
    else cfg.browserStreamSelectorRemoteAddress;
  directDrmStreamEnabled = cfg.enableDirectDrmStream && directStreamEnabled;
  directDrmBrowserEnabled = cfg.enableDirectDrmBrowserStreams && browserStreamEnabled;
  persistentDirectDrmBrowserDefault = cfg.defaultSessionMode == "direct-browser";
  compositorSessionCondition = pkgs.writeShellScript "nixbox-compositor-session-condition" ''
    mode="$(
      tr -d '[:space:]' \
        < ${lib.escapeShellArg modeStateFile} \
        2>/dev/null \
        || true
    )"
    case "''${mode%%:*}" in
      couch${
      lib.optionalString (cfg.desktopSessionCommand != null) " | desktop"
    }${lib.optionalString cfg.enableMergedProfile " | merged"})
        exit 0
        ;;
      *)
        exit 1
        ;;
    esac
  '';
  sessionModeSwitchEnabled =
    cfg.autoLoginUser
    != null
    && (cfg.desktopSessionCommand != null || directDrmStreamEnabled || directDrmBrowserEnabled);
  directModeInputShortcutsEnabled =
    cfg.enableDirectModeInputShortcuts
    && sessionModeSwitchEnabled
    && (directDrmStreamEnabled || directDrmBrowserEnabled);
  kdeConnectDirectInputEnabled =
    cfg.enableKdeConnect && (directDrmStreamEnabled || directDrmBrowserEnabled);
  dynamicExternalLayoutEnabled = cfg.autoLayoutExternalOutputs || cfg.autoMirrorExternalOutputs;
  defaultOutputMode =
    if dynamicExternalLayoutEnabled
    then lib.last cfg.autoLayoutSecondaryModes
    else cfg.outputMode;
  mirrorOutputMode =
    if cfg.mirrorOutputMode == null
    then cfg.outputMode
    else cfg.mirrorOutputMode;
  autoMirrorOutputMode =
    if cfg.mirrorOutputMode == null
    then ""
    else cfg.mirrorOutputMode;
  autoMirrorSecondaryPosition =
    if cfg.autoMirrorSecondaryPosition == null
    then cfg.autoLayoutSecondaryPosition
    else cfg.autoMirrorSecondaryPosition;
  autoMirrorTertiaryPosition =
    if cfg.autoMirrorTertiaryPosition == null
    then cfg.autoLayoutTertiaryPosition
    else cfg.autoMirrorTertiaryPosition;
  mirrorSourceOutputs = lib.unique (lib.attrValues cfg.mirrorOutputs);
  directDrmEnvironment =
    [
      "QT_QPA_PLATFORM=eglfs"
    ]
    ++ lib.optionals directDrmKmsConfigEnabled [
      "QT_QPA_EGLFS_INTEGRATION=eglfs_kms"
      "QT_QPA_EGLFS_KMS_CONFIG=${directDrmActiveKmsConfigFile}"
    ]
    ++ lib.optional (cfg.directDrmFixedOutput != null)
    "QT_QPA_EGLFS_ALWAYS_SET_MODE=1"
    ++ cfg.directDrmExtraEnvironment;
  mkMoonlightExecutable = name: profileDirectory:
    if profileDirectory == null
    then lib.getExe moonlightPackage
    else
      lib.getExe (
        pkgs.writeShellApplication {
          name = "moonlight-${name}";
          runtimeInputs = [pkgs.coreutils];
          text = ''
            install -d -m 0700 \
              ${lib.escapeShellArg "${profileDirectory}/config"} \
              ${lib.escapeShellArg "${profileDirectory}/cache"} \
              ${lib.escapeShellArg "${profileDirectory}/data"}
            export XDG_CONFIG_HOME=${lib.escapeShellArg "${profileDirectory}/config"}
            export XDG_CACHE_HOME=${lib.escapeShellArg "${profileDirectory}/cache"}
            export XDG_DATA_HOME=${lib.escapeShellArg "${profileDirectory}/data"}
            exec ${lib.getExe moonlightPackage} "$@"
          '';
        }
      );
  defaultMoonlightExecutable = mkMoonlightExecutable "default" null;
  selectorMoonlightExecutable = mkMoonlightExecutable "browser-selector" cfg.browserStreamSelectorProfileDirectory;
  mkMoonlightInvocation = executable: extraEnvironment: extraArguments: host: application:
    lib.escapeShellArgs (
      [
        "${pkgs.coreutils}/bin/env"
        "QT_QPA_PLATFORM=${cfg.moonlightPlatform}"
      ]
      ++ extraEnvironment
      ++ [
        executable
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
    if directStreamEnabled
    then mkMoonlightInvocation defaultMoonlightExecutable [] [] cfg.streamHost cfg.streamApplication
    else
      lib.escapeShellArgs [
        "${pkgs.coreutils}/bin/env"
        "QT_QPA_PLATFORM=${cfg.moonlightPlatform}"
        defaultMoonlightExecutable
      ];
  directDrmMoonlightInvocation = lib.optionalString directDrmStreamEnabled (
    mkMoonlightInvocation defaultMoonlightExecutable directDrmEnvironment cfg.directDrmStreamArguments
    cfg.streamHost
    cfg.streamApplication
  );
  browserMoonlightInvocation = lib.optionalString browserStreamEnabled (
    mkMoonlightInvocation defaultMoonlightExecutable (
      [
        "MOONLIGHT_POLL_ABSOLUTE_MOUSE=1"
        "MOONLIGHT_ABSOLUTE_MOUSE_POLL_INTERVAL_MS=${toString cfg.browserAbsoluteMousePollIntervalMs}"
        "MOONLIGHT_ABSOLUTE_MOUSE_SENSITIVITY=${toString cfg.browserAbsoluteMouseSensitivity}"
      ]
      ++ lib.optional cfg.browserShowLocalCursor "MOONLIGHT_SHOW_LOCAL_CURSOR=1"
    )
    cfg.browserStreamArguments
    cfg.browserStreamHost
    cfg.browserStreamApplication
  );
  browserSelectorMoonlightInvocation = lib.optionalString browserSelectorEnabled (
    mkMoonlightInvocation selectorMoonlightExecutable (
      [
        "MOONLIGHT_POLL_ABSOLUTE_MOUSE=1"
        "MOONLIGHT_ABSOLUTE_MOUSE_POLL_INTERVAL_MS=${toString cfg.browserAbsoluteMousePollIntervalMs}"
        "MOONLIGHT_ABSOLUTE_MOUSE_SENSITIVITY=${toString cfg.browserAbsoluteMouseSensitivity}"
      ]
      ++ lib.optional cfg.browserShowLocalCursor "MOONLIGHT_SHOW_LOCAL_CURSOR=1"
    )
    cfg.browserStreamArguments
    browserSelectorHost
    cfg.browserStreamSelectorApplication
  );
  directDrmBrowserMoonlightInvocation = lib.optionalString directDrmBrowserEnabled (
    mkMoonlightInvocation defaultMoonlightExecutable (
      [
        "MOONLIGHT_POLL_ABSOLUTE_MOUSE=1"
        "MOONLIGHT_ABSOLUTE_MOUSE_POLL_INTERVAL_MS=${toString cfg.browserAbsoluteMousePollIntervalMs}"
        "MOONLIGHT_ABSOLUTE_MOUSE_SENSITIVITY=${toString cfg.browserAbsoluteMouseSensitivity}"
      ]
      ++ lib.optional cfg.browserShowLocalCursor "MOONLIGHT_SHOW_LOCAL_CURSOR=1"
      ++ directDrmEnvironment
    )
    cfg.browserStreamArguments
    cfg.browserStreamHost
    cfg.browserStreamApplication
  );
  directDrmBrowserSelectorMoonlightInvocation =
    lib.optionalString (directDrmBrowserEnabled && browserSelectorEnabled)
    (
      mkMoonlightInvocation selectorMoonlightExecutable (
        [
          "MOONLIGHT_POLL_ABSOLUTE_MOUSE=1"
          "MOONLIGHT_ABSOLUTE_MOUSE_POLL_INTERVAL_MS=${toString cfg.browserAbsoluteMousePollIntervalMs}"
          "MOONLIGHT_ABSOLUTE_MOUSE_SENSITIVITY=${toString cfg.browserAbsoluteMouseSensitivity}"
        ]
        ++ lib.optional cfg.browserShowLocalCursor "MOONLIGHT_SHOW_LOCAL_CURSOR=1"
        ++ directDrmEnvironment
      )
      cfg.browserStreamArguments
      browserSelectorHost
      cfg.browserStreamSelectorApplication
    );

  endpointSetup = import ./endpoints.nix {
    inherit
      browserSelectorHost
      browserSelectorLocalAddress
      browserSelectorRemoteAddress
      browserStreamEnabled
      cfg
      lib
      pkgs
      selectorMoonlightExecutable
      ;
  };
  inherit
    (endpointSetup)
    browserSelectorEndpointSetup
    browserSelectorPair
    browserStreamEndpointPolicyEnabled
    browserStreamReadinessHosts
    moonlightEndpointSetup
    streamEndpointPolicyEnabled
    streamReadinessHosts
    ;

  activeKeyboardLayout = pkgs.writeShellApplication {
    name = "couch-active-keyboard-layout";
    runtimeInputs =
      [pkgs.coreutils]
      ++ lib.optionals cfg.enableCompositedSession [
        pkgs.hyprland
        pkgs.jq
      ];
    text =
      if !cfg.enableCompositedSession
      then ''
        configured_layouts=${lib.escapeShellArg cfg.keyboardLayouts}
        printf '%s\n' "''${configured_layouts%%,*}"
      ''
      else ''
        configured_layouts=${lib.escapeShellArg cfg.keyboardLayouts}
        fallback_layout="''${configured_layouts%%,*}"
        active_keymap=""

        # Give hot-plugged USB receivers a brief chance to appear at graphical
        # login. Hyprland's "main" keyboard can remain the internal laptop
        # device even while an external keyboard is the one being used.
        for attempt in $(seq 1 20); do
          devices="$(hyprctl -j devices 2>/dev/null || true)"
          if printf '%s' "$devices" \
            | jq -e 'type == "object" and (.keyboards | type == "array")' \
              >/dev/null 2>&1; then
            while IFS= read -r keyboard_name; do
              keyboard_name="$(printf '%s' "$keyboard_name" | tr '[:upper:]' '[:lower:]')"
              case "$keyboard_name" in
                ${lib.concatStringsSep "\n              " (
          lib.flatten (
            lib.mapAttrsToList (
              layout: matches:
                map (
                  match: "*${lib.escapeShellArg (lib.toLower match)}*) printf '%s\\n' ${lib.escapeShellArg layout}; exit 0 ;;"
                )
                matches
            )
            cfg.keyboardLayoutDeviceOverrides
          )
        )}
              esac
            done < <(printf '%s' "$devices" | jq -r '.keyboards[].name')

            active_keymap="$(
              printf '%s' "$devices" \
                | jq -r 'first(.keyboards[] | select(.main)).active_keymap // empty'
            )"
            if [ "$attempt" -ge 8 ] && [ -n "$active_keymap" ]; then
              break
            fi
          fi
          sleep 0.25
        done

        case "$active_keymap" in
          *Norwegian*) printf '%s\n' no ;;
          *"English (US)"*) printf '%s\n' us ;;
          *) printf '%s\n' "$fallback_layout" ;;
        esac
      '';
  };

  directDrmHelpers = import ./direct-drm.nix {
    inherit
      browserSelectorEndpointSetup
      cfg
      directDrmActiveKmsConfigFile
      directDrmBrowserMoonlightInvocation
      directDrmBrowserSelectorMoonlightInvocation
      directDrmKeyboardLayoutFile
      directDrmKmsConfigFile
      directDrmMoonlightInvocation
      directDrmReturnModeFile
      lib
      modeStateFile
      moonlightEndpointSetup
      persistentDirectDrmBrowserDefault
      pkgs
      qtConnectorName
      streamReadinessHosts
      ;
  };
  inherit
    (directDrmHelpers)
    directDrmBrowserSelectorSession
    directDrmBrowserSession
    directDrmOutputSnapshot
    directDrmStreamSession
    ;

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

  browserSessionHelpers = import ./browser-sessions.nix {
    inherit
      activeKeyboardLayout
      browserMoonlightInvocation
      browserSelectorEndpointSetup
      browserSelectorMoonlightInvocation
      browserStreamReadinessHosts
      cfg
      directStreamEnabled
      displayModeSetup
      hdmiAudioSetup
      lib
      moonlightEndpointSetup
      moonlightInvocation
      moonlightPackage
      pkgs
      streamReadinessHosts
      ;
  };
  inherit
    (browserSessionHelpers)
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

  audioHelpers = import ./audio.nix {
    inherit cfg lib pkgs displayLayoutStateFile modeStateFile waitForStableOutputs;
  };
  inherit (audioHelpers) audioOutputControl audioHealthRecovery audioLayoutSync;

  layoutHelpers = import ./layout.nix {
    inherit
      audioOutputControl
      autoMirrorOutputMode
      autoMirrorSecondaryPosition
      autoMirrorTertiaryPosition
      cfg
      displayLayoutStateFile
      dynamicMonitorConfigFile
      lib
      mirrorStateFile
      pkgs
      ;
  };
  inherit
    (layoutHelpers)
    autoLayoutExternalOutputs
    couchWorkspace
    displayLayoutControl
    displayMirrorToggle
    softwareMirror
    ;

  sessionControlHelpers = import ./session-control.nix {
    inherit
      activeKeyboardLayout
      audioOutputControl
      browserSelectorEnabled
      cfg
      directDrmBrowserEnabled
      directDrmKeyboardLayoutFile
      directDrmKmsConfigFile
      directDrmOutputSnapshot
      directDrmReturnModeFile
      directDrmStreamEnabled
      displayLayoutControl
      displayMirrorToggle
      lib
      mergedDmsCheatsheetFile
      mergedDmsConfigDirectory
      mergedDmsSettingsFile
      modeStateFile
      persistentDirectDrmBrowserDefault
      pkgs
      ;
  };
  inherit
    (sessionControlHelpers)
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

  inputHelpers = import ./input.nix {
    inherit
      audioOutputControl
      browserSelectorEnabled
      browserStreamEnabled
      cfg
      couchBrowser
      directDrmBrowserEnabled
      directDrmStreamEnabled
      displayLayoutControl
      displayMirrorToggle
      kdeConnectDirectInputEnabled
      kdeConnectExecutable
      kdeConnectHyprlandInput
      lib
      mergedUiControl
      modeStateFile
      pkgs
      sessionMode
      ;
  };
  inherit
    (inputHelpers)
    closeActiveWindow
    controllerDaemon
    couchControlHelp
    couchStreamControl
    directModeInputDaemon
    kdeConnectDbusServiceOverride
    kdeConnectSessionLauncher
    pointerSync
    ;

  sessionArtifactHelpers = import ./session-artifacts.nix {
    inherit
      audioOutputControl
      autoLayoutExternalOutputs
      browserSelectorEnabled
      browserStreamEnabled
      cfg
      closeActiveWindow
      controllerDaemon
      couchBrowser
      couchBrowserNewWindow
      couchBrowserStartup
      couchControlHelp
      couchFallbackBrowser
      couchStreamControl
      couchTerminal
      couchWorkspace
      defaultOutputMode
      directDrmBrowserEnabled
      directDrmBrowserSelectorSession
      directDrmBrowserSession
      directDrmStreamEnabled
      directDrmStreamSession
      displayLayoutControl
      displayMirrorToggle
      dynamicExternalLayoutEnabled
      dynamicMonitorConfigFile
      lib
      mergedDmsServiceControl
      mirrorOutputMode
      mirrorSourceOutputs
      modeStateFile
      moonlightSession
      persistentDirectDrmBrowserDefault
      pkgs
      pointerSync
      protectedBrowser
      sessionMode
      sessionSplashLaunch
      softwareMirror
      ;
  };
  inherit
    (sessionArtifactHelpers)
    couchApplications
    sessionCommand
    sessionDispatcher
    sessionPackage
    ;
in {
  options.services.moonlight-client = import ./options.nix {
    inherit lib pkgs kdeConnectInputDefaults;
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages =
      [moonlightPackage]
      ++ lib.optionals cfg.enableCompositedSession [
        couchApplications
        couchStreamControl
        closeActiveWindow
        moonlightStreamStart
      ]
      ++ lib.optionals cfg.enableLocalUtilities [
        cfg.terminalPackage
        couchTerminal
      ]
      ++ lib.optionals cfg.enableLocalBrowser [
        cfg.browserPackage
        couchBrowser
        couchBrowserStartup
        couchBrowserNewWindow
      ]
      ++ lib.optional (
        browserSelectorEnabled && cfg.browserStreamSelectorProfileDirectory != null
      )
      browserSelectorPair
      ++ lib.optional cfg.enableControllerShortcuts controllerDaemon
      ++ lib.optional cfg.enableControllerShortcuts couchControlHelp
      ++ lib.optional directModeInputShortcutsEnabled directModeInputDaemon
      ++ lib.optional (cfg.cursorThemePackage != null) cfg.cursorThemePackage
      ++ lib.optionals cfg.enableKdeConnect [
        pointerSync
        (lib.hiPrio kdeConnectDbusServiceOverride)
      ]
      ++ lib.optional cfg.enableMergedProfile mergedDmsSession
      ++ lib.optional cfg.enableMergedProfile mergedUiControl
      ++ lib.optional (cfg.softwareMirrorOutputs != {}) softwareMirror
      ++ lib.optional cfg.enableMirrorToggle displayMirrorToggle
      ++ lib.optional cfg.enableAdaptiveDisplayLayout displayLayoutControl
      ++ lib.optional cfg.enableAudioOutputCycle audioOutputControl
      ++ lib.optional cfg.enableAudioOutputCycle audioLayoutSync
      ++ lib.optional (cfg.sessionSplashCommand != null) sessionPowerAction
      ++ lib.optional dynamicExternalLayoutEnabled autoLayoutExternalOutputs
      ++ lib.optional (
        cfg.enableLocalBrowser && cfg.fallbackBrowserPackage != null
      )
      cfg.fallbackBrowserPackage
      ++ lib.optional (
        cfg.enableLocalBrowser && cfg.fallbackBrowserPackage != null
      )
      couchFallbackBrowser.package
      ++ lib.optional (cfg.protectedBrowserPackage != null) protectedBrowser
      ++ lib.optional sessionModeSwitchEnabled sessionMode;
    services.displayManager.sessionPackages = lib.optional cfg.enableCompositedSession sessionPackage;

    # Install udev rules for common controllers, including Steam hardware.
    hardware.steam-hardware.enable = true;

    programs.kdeconnect.enable = cfg.enableKdeConnect;

    hardware.uinput = lib.mkIf kdeConnectDirectInputEnabled {
      enable = true;
    };

    # Route both eager startup and D-Bus activation through one supervised
    # XWayland daemon. The preload shim preserves KDE Connect's XTest keyboard,
    # click and scroll path while forwarding pointer motion rejected by
    # XWayland to the session-local Hyprland bridge.
    systemd.user.services.kdeconnect = lib.mkIf cfg.enableKdeConnect {
      description = "KDE Connect with Hyprland pointer integration";
      environment = {
        KDECONNECT_SCROLL_INTERVAL_MS = toString cfg.kdeConnectScrollIntervalMs;
        KDECONNECT_POINTER_SENSITIVITY = toString cfg.kdeConnectPointerSensitivity;
        KDECONNECT_POINTER_PRECISION_SENSITIVITY =
          toString cfg.kdeConnectPointerPrecisionSensitivity;
        KDECONNECT_POINTER_ACCELERATION_START =
          toString cfg.kdeConnectPointerAccelerationStart;
        KDECONNECT_POINTER_ACCELERATION_FULL =
          toString cfg.kdeConnectPointerAccelerationFull;
        QT_QPA_PLATFORM = "xcb";
        LD_PRELOAD = "${kdeConnectHyprlandInput}/lib/libkdeconnect-hypr-pointer-shim.so";
      };
      serviceConfig = {
        Type = "dbus";
        BusName = "org.kde.kdeconnect";
        ExecStart = lib.getExe kdeConnectSessionLauncher;
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    systemd.user.services.nixbox-direct-input =
      lib.mkIf (
        directModeInputShortcutsEnabled || kdeConnectDirectInputEnabled
      ) {
        description = "Direct-display shortcuts and KDE Connect input bridge";
        wantedBy = ["default.target"];
        serviceConfig = {
          Type = "simple";
          ExecStart = lib.getExe directModeInputDaemon;
          Restart = "always";
          RestartSec = 1;
        };
      };

    systemd.user.services.couch-moonlight-stream = lib.mkIf cfg.enableControllerShortcuts {
      description = "Controller-launched Moonlight stream";
      restartIfChanged = false;
      serviceConfig = {
        Type = "simple";
        ExecStartPre = "-${lib.getExe mergedUiControl} game";
        ExecStart = lib.getExe moonlightStreamStart;
        ExecStopPost = "-${lib.getExe mergedUiControl} refresh";
        TimeoutStartSec = cfg.streamStartupTimeout + 30;
        TimeoutStopSec = 3;
        KillMode = "control-group";
        SendSIGKILL = true;
      };
    };

    systemd.user.services.couch-moonlight-browser-stream =
      lib.mkIf (
        cfg.enableCompositedSession && browserStreamEnabled
      ) {
        description = "Controller-launched remote browser stream";
        restartIfChanged = false;
        serviceConfig = {
          Type = "simple";
          ExecStartPre = "-${lib.getExe mergedUiControl} game";
          ExecStart = lib.getExe moonlightBrowserSession;
          ExecStopPost = "-${lib.getExe mergedUiControl} refresh";
          TimeoutStopSec = 3;
          KillMode = "control-group";
          SendSIGKILL = true;
        };
      };

    systemd.user.services.couch-moonlight-browser-selector =
      lib.mkIf (
        cfg.enableCompositedSession && browserSelectorEnabled
      ) {
        description = "PIN-protected remote browser selector";
        restartIfChanged = false;
        serviceConfig = {
          Type = "simple";
          ExecStartPre = "-${lib.getExe mergedUiControl} game";
          ExecStart = lib.getExe moonlightBrowserSelectorSession;
          ExecStopPost = "-${lib.getExe mergedUiControl} refresh";
          TimeoutStopSec = 3;
          KillMode = "control-group";
          SendSIGKILL = true;
        };
      };

    systemd.user.services.couch-protected-browser =
      lib.mkIf (
        cfg.enableCompositedSession && cfg.protectedBrowserPackage != null
      ) {
        description = "Independent protected couch browser supervisor";
        serviceConfig = {
          Type = "exec";
          ExecStart = lib.getExe protectedBrowserSession;
        };
      };

    systemd.user.services.xdg-desktop-portal-gtk =
      lib.mkIf (
        cfg.enableCompositedSession && persistentDirectDrmBrowserDefault
      ) {
        overrideStrategy = "asDropin";
        serviceConfig.ExecCondition = compositorSessionCondition;
      };

    systemd.user.services.couch-dms = lib.mkIf cfg.enableDms {
      description = "Supervised DMS shell for the dedicated couch session";
      serviceConfig = {
        Type = "simple";
        ExecStart = lib.getExe dmsSession;
        Restart = "always";
        RestartSec = 2;
        SuccessExitStatus = 143;
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

    systemd.user.services.couch-audio-health-recovery = lib.mkIf cfg.enableAudioHealthRecovery {
      description = "Reconcile couch audio and recover stalled routes";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe audioHealthRecovery;
        TimeoutStartSec = 60;
      };
    };

    systemd.user.services.couch-audio-follow-layout = lib.mkIf cfg.enableAudioOutputCycle {
      description = "Select couch audio after the display layout settles";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe audioLayoutSync;
        TimeoutStartSec = 45;
      };
    };

    systemd.user.timers.couch-audio-health-recovery = lib.mkIf cfg.enableAudioHealthRecovery {
      description = "Reconcile couch audio routes and verify responsiveness";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "10s";
        OnUnitActiveSec = "5s";
        AccuracySec = "1s";
        Unit = "couch-audio-health-recovery.service";
      };
    };

    services.greetd.settings.initial_session = lib.mkIf (cfg.autoLoginUser != null) {
      command =
        if sessionModeSwitchEnabled
        then lib.getExe sessionDispatcher
        else sessionCommand;
      user = cfg.autoLoginUser;
    };

    # greetd validates default_session even when initial_session handles the
    # automatic login. Direct-only appliances have no desktop greeter, so use
    # the same dispatcher as their recovery session as well.
    services.greetd.settings.default_session =
      lib.mkIf (
        cfg.autoLoginUser != null && !cfg.enableCompositedSession
      ) {
        command =
          if sessionModeSwitchEnabled
          then lib.getExe sessionDispatcher
          else sessionCommand;
        user = cfg.autoLoginUser;
      };

    # A persistent direct-display appliance must recover its initial session
    # after an operator or service restart as well as after a mode-file change.
    systemd.services.greetd.preStart = lib.mkIf persistentDirectDrmBrowserDefault ''
      rm -f /run/greetd.run
    '';

    # Direct-display appliances have no fallback greeter or compositor. Keep
    # the display session supervised even when greetd's child exits cleanly.
    systemd.services.greetd.serviceConfig = lib.mkIf persistentDirectDrmBrowserDefault {
      Restart = "always";
      RestartSec = 2;
    };

    systemd.tmpfiles.rules =
      lib.optional (
        cfg.autoLoginUser != null && (sessionModeSwitchEnabled || cfg.enableAdaptiveDisplayLayout)
      ) "d ${modeStateDirectory} 0755 ${cfg.autoLoginUser} root - -"
      ++ lib.optional sessionModeSwitchEnabled "${
        if persistentDirectDrmBrowserDefault
        then "f+"
        else "f"
      } ${modeStateFile} 0644 ${cfg.autoLoginUser} root - ${cfg.defaultSessionMode}"
      ++ lib.optional ((directDrmStreamEnabled || directDrmBrowserEnabled) && cfg.autoLoginUser != null)
      "${
        if persistentDirectDrmBrowserDefault
        then "f+"
        else "f"
      } ${directDrmReturnModeFile} 0644 ${cfg.autoLoginUser} root - ${cfg.defaultSessionMode}"
      ++ lib.optional ((directDrmStreamEnabled || directDrmBrowserEnabled) && cfg.autoLoginUser != null)
      "f ${directDrmKeyboardLayoutFile} 0644 ${cfg.autoLoginUser} root - ${builtins.head (lib.splitString "," cfg.keyboardLayouts)}"
      ++ lib.optional (
        cfg.directDrmAutoSelectOutput && cfg.autoLoginUser != null
      ) "f ${directDrmKmsConfigFile} 0644 ${cfg.autoLoginUser} root -"
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

    systemd.paths.couch-session-mode-switch = lib.mkIf sessionModeSwitchEnabled {
      description = "Watch for Nixbox session mode changes";
      wantedBy = ["multi-user.target"];
      pathConfig = {
        PathChanged = modeStateFile;
        Unit = "couch-session-mode-switch.service";
      };
    };

    systemd.services.couch-session-mode-switch = lib.mkIf sessionModeSwitchEnabled {
      description = "Restart greetd after a Nixbox session mode change";
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
        assertion = cfg.enableCompositedSession || cfg.defaultSessionMode == "direct-browser";
        message = "services.moonlight-client without a composited session requires direct-browser as its default session mode";
      }
      {
        assertion =
          cfg.kdeConnectPointerPrecisionSensitivity
          <= cfg.kdeConnectPointerSensitivity;
        message = "KDE Connect precision pointer gain must not exceed its maximum gain";
      }
      {
        assertion =
          cfg.kdeConnectPointerAccelerationStart
          < cfg.kdeConnectPointerAccelerationFull;
        message = "KDE Connect pointer acceleration full speed must exceed its start speed";
      }
      {
        assertion = cfg.autoLoginUser == null || config.services.greetd.enable;
        message = "services.moonlight-client.autoLoginUser requires services.greetd.enable";
      }
      {
        assertion = cfg.desktopSessionCommand == null || cfg.autoLoginUser != null;
        message = "services.moonlight-client.desktopSessionCommand requires autoLoginUser";
      }
      {
        assertion = !cfg.enableDirectDrmStream || cfg.autoLoginUser != null;
        message = "services.moonlight-client.enableDirectDrmStream requires autoLoginUser";
      }
      {
        assertion = !cfg.enableDirectDrmStream || directStreamEnabled;
        message = "services.moonlight-client.enableDirectDrmStream requires a configured primary stream";
      }
      {
        assertion = !cfg.directDrmAutoSelectOutput || (directDrmStreamEnabled || directDrmBrowserEnabled);
        message = "services.moonlight-client.directDrmAutoSelectOutput requires a configured direct-DRM stream";
      }
      {
        assertion = cfg.directDrmFixedOutput == null || (directDrmStreamEnabled || directDrmBrowserEnabled);
        message = "services.moonlight-client.directDrmFixedOutput requires a configured direct-DRM stream";
      }
      {
        assertion = !cfg.directDrmAutoSelectOutput || cfg.directDrmFixedOutput == null;
        message = "services.moonlight-client directDrmAutoSelectOutput and directDrmFixedOutput are mutually exclusive";
      }
      {
        assertion = cfg.directDrmAudioOutputByConnector == {} || directDrmKmsConfigEnabled;
        message = "services.moonlight-client.directDrmAudioOutputByConnector requires a direct DRM KMS configuration";
      }
      {
        assertion = !cfg.enableDirectDrmBrowserStreams || cfg.autoLoginUser != null;
        message = "services.moonlight-client.enableDirectDrmBrowserStreams requires autoLoginUser";
      }
      {
        assertion = !cfg.enableDirectDrmBrowserStreams || browserStreamEnabled;
        message = "services.moonlight-client.enableDirectDrmBrowserStreams requires a configured browser stream";
      }
      {
        assertion = cfg.defaultSessionMode != "merged" || cfg.enableMergedProfile;
        message = "services.moonlight-client.defaultSessionMode = merged requires enableMergedProfile";
      }
      {
        assertion = cfg.defaultSessionMode != "direct-browser" || directDrmBrowserEnabled;
        message = "services.moonlight-client.defaultSessionMode = direct-browser requires a configured direct browser stream";
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
        assertion =
          !cfg.autoStartBrowser
          || cfg.enableLocalBrowser
          || (cfg.preferRemoteBrowserAtStartup && browserStreamEnabled);
        message = ''
          services.moonlight-client.autoStartBrowser requires a local browser
          or a preferred remote browser stream
        '';
      }
      {
        assertion = cfg.browserStreamSelectorApplication == null || browserStreamEnabled;
        message = "services.moonlight-client browser selector requires a browser stream host and application";
      }
      {
        assertion = cfg.browserStreamSelectorHost == null || cfg.browserStreamSelectorApplication != null;
        message = "services.moonlight-client.browserStreamSelectorHost requires a browser selector";
      }
      {
        assertion = cfg.browserStreamSelectorPort == null || cfg.browserStreamSelectorApplication != null;
        message = "services.moonlight-client.browserStreamSelectorPort requires a browser selector";
      }
      {
        assertion =
          (cfg.browserStreamSelectorLocalAddress == null)
          == (cfg.browserStreamSelectorRemoteAddress == null);
        message = "services.moonlight-client selector local and remote addresses must be set together";
      }
      {
        assertion =
          cfg.browserStreamSelectorLocalAddress
          == null
          || cfg.browserStreamSelectorApplication != null;
        message = "services.moonlight-client selector addresses require a browser selector";
      }
      {
        assertion =
          cfg.browserStreamSelectorProfileDirectory
          == null
          || lib.hasPrefix "/" cfg.browserStreamSelectorProfileDirectory;
        message = "services.moonlight-client.browserStreamSelectorProfileDirectory must be absolute";
      }
      {
        assertion = cfg.controllerHoldSeconds > 0.0;
        message = "services.moonlight-client.controllerHoldSeconds must be positive";
      }
      {
        assertion =
          !cfg.enableDirectModeInputShortcuts || (directDrmBrowserEnabled || directDrmStreamEnabled);
        message = "services.moonlight-client.enableDirectModeInputShortcuts requires a configured direct-display stream";
      }
      {
        assertion = cfg.browserScaleFactor > 0.0;
        message = "services.moonlight-client.browserScaleFactor must be positive";
      }
      {
        assertion = lib.elem cfg.browserPresentationScale [
          1.0
          1.5
        ];
        message = "services.moonlight-client.browserPresentationScale must be 1.0 or 1.5";
      }
      {
        assertion = lib.all (layout: lib.elem layout (lib.splitString "," cfg.keyboardLayouts)) (
          lib.attrNames cfg.keyboardLayoutDeviceOverrides
        );
        message = ''
          services.moonlight-client.keyboardLayoutDeviceOverrides keys must
          name layouts configured in keyboardLayouts
        '';
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
          lib.intersectLists cfg.autoLayoutPrimaryWorkspaces cfg.autoLayoutSecondaryWorkspaces == [];
        message = "services.moonlight-client automatic primary and secondary workspace sets must not overlap";
      }
      {
        assertion =
          lib.intersectLists cfg.autoLayoutPrimaryWorkspaces cfg.autoLayoutTertiaryWorkspaces
          == []
          && lib.intersectLists cfg.autoLayoutSecondaryWorkspaces cfg.autoLayoutTertiaryWorkspaces == [];
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
