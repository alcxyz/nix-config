{
  lib,
  pkgs,
  kdeConnectInputDefaults,
}: {
  enable = lib.mkEnableOption "a dedicated Moonlight Hyprland session";

  enableCompositedSession = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Provide the Hyprland couch session and use it as the recovery path.
      Disable this for direct-display appliances whose only sessions let
      Moonlight own DRM through EGLFS.
    '';
  };

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

  streamEndpointMode = lib.mkOption {
    type = lib.types.enum [
      "lan-only"
      "lan-first"
      "remote-only"
    ];
    default = "lan-first";
    description = ''
      Endpoint policy for the direct stream. LAN-only and remote-only pin
      every saved Moonlight address field to the selected endpoint; LAN-first
      retains an explicit remote fallback.
    '';
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

  browserStreamSelectorHost = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''
      Optional independent paired Moonlight host for the protected browser
      selector. Null keeps the selector on browserStreamHost.
    '';
  };

  browserStreamSelectorPort = lib.mkOption {
    type = lib.types.nullOr lib.types.port;
    default = null;
    description = ''
      Optional nonstandard HTTP port for an isolated protected browser
      coordinator.
    '';
  };

  browserStreamSelectorLocalAddress = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''
      Optional RFC 1918 address for an independent protected-browser
      selector host. Null inherits browserStreamLocalAddress.
    '';
  };

  browserStreamSelectorRemoteAddress = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''
      Optional VPN fallback address for an independent protected-browser
      selector host. Null inherits browserStreamRemoteAddress.
    '';
  };

  browserStreamSelectorProfileDirectory = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''
      Optional absolute directory containing isolated XDG config, cache, and
      data homes for the protected browser selector. Set this when the public
      browser and selector must stream concurrently from the same host.
    '';
  };

  enableDirectDrmBrowserStreams = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Offer one-shot browser sessions where Moonlight owns DRM through
      EGLFS instead of rendering through Hyprland. Exiting the stream
      automatically returns to the previous graphical session mode.
    '';
  };

  enableDirectDrmStream = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Offer a one-shot primary Moonlight stream where Moonlight owns DRM
      through EGLFS instead of rendering through Hyprland. Exiting the
      stream automatically returns to the previous graphical session mode.
    '';
  };

  directDrmAutoSelectOutput = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Before entering a one-shot direct-DRM session, snapshot the focused
      powered Hyprland output and generate a Qt EGLFS KMS configuration that
      uses its DRM device and current pixel dimensions while turning off
      other connected outputs on that device. This is intended for
      multi-GPU or multi-output couch hosts; fixed single-output appliances
      can retain EGLFS discovery.
    '';
  };

  directDrmFixedOutput = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          device = lib.mkOption {
            type = lib.types.str;
            example = "/dev/dri/card0";
            description = "DRM device used by the fixed direct-display output.";
          };

          connector = lib.mkOption {
            type = lib.types.str;
            example = "HDMI-A-1";
            description = "Kernel DRM connector used by the fixed direct-display output.";
          };

          mode = lib.mkOption {
            type = lib.types.str;
            example = "1920x1080@60";
            description = "Exact Qt EGLFS KMS mode used by the fixed direct-display output.";
          };

          disabledConnectors = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            example = [
              "eDP-1"
              "DP-2"
            ];
            description = ''
              Other connectors on the DRM device that Qt EGLFS must disable
              while the fixed direct-display output owns scanout.
            '';
          };
        };
      }
    );
    default = null;
    description = ''
      Generate a static Qt EGLFS KMS configuration for a fixed direct-DRM
      output. This prevents EGLFS from replacing the configured mode with the
      display's preferred mode or presenting on another connected output.
    '';
  };

  directDrmAudioOutputByConnector = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    example = {
      "DP-1" = "Living room TV";
      "HDMI-A-1" = "Desk display";
    };
    description = ''
      PipeWire sinks selected together with each connector in a direct-DRM
      session. Connector names use their kernel/Hyprland form; each value
      must match the sink's PipeWire node name, WirePlumber description, or
      nickname. The composited couch session also uses this association when
      exactly one external connector is enabled, preventing a semantic
      display-layout fallback from selecting another connector's HDMI PCM.
    '';
  };

  directDrmExtraEnvironment = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    example = ["MOONLIGHT_VIDEO_STATS_LOG_INTERVAL_MS=5000"];
    description = "Additional NAME=VALUE environment entries for direct-DRM Moonlight sessions.";
  };

  directDrmLogToJournal = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Mirror direct-DRM Moonlight output to the system journal while
      retaining it on the appliance's virtual console.
    '';
  };

  directDrmStreamArguments = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = "Additional Moonlight arguments used only by the direct-DRM primary stream.";
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

  browserStreamEndpointMode = lib.mkOption {
    type = lib.types.enum [
      "lan-only"
      "lan-first"
      "remote-only"
    ];
    default = "lan-first";
    description = ''
      Endpoint policy for the browser stream. LAN-only and remote-only pin
      every saved Moonlight address field to the selected endpoint; LAN-first
      retains an explicit remote fallback.
    '';
  };

  browserStreamArguments = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = "Additional Moonlight arguments used only for the remote browser stream.";
  };

  browserAbsoluteMouseSensitivity = lib.mkOption {
    type = lib.types.numbers.positive;
    default = 1.0;
    description = ''
      Client-side pointer multiplier used by polled absolute-mouse browser
      sessions. Values above one increase physical pointer sensitivity
      without changing the remote absolute coordinate mapping.
    '';
  };

  browserAbsoluteMousePollIntervalMs = lib.mkOption {
    type = lib.types.ints.positive;
    default = 8;
    description = ''
      Poll interval in milliseconds for physical pointer input in
      absolute-mouse browser sessions.
    '';
  };

  browserShowLocalCursor = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Show Moonlight's local cursor during browser streams. Disable this for
      direct-display clients where the local cursor otherwise remains parked
      over the streamed desktop.
    '';
  };

  browserStreamLayoutCommand = lib.mkOption {
    type = lib.types.nullOr lib.types.lines;
    default = null;
    description = ''
      Optional command that aligns a newly started remote browser with the
      main local keyboard. COUCH_KEYBOARD_LAYOUT and
      COUCH_STREAM_APPLICATION are exported for the command.
    '';
  };

  browserStreamPrepareCommand = lib.mkOption {
    type = lib.types.nullOr lib.types.lines;
    default = null;
    description = ''
      Optional command run before connecting to the public remote browser.
      This can clear client-specific stale server state after an unclean
      local exit without affecting other cooperative clients.
    '';
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

  enableDirectModeInputShortcuts = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Run a persistent non-grabbing keyboard and controller listener for
      direct-display session switching. The listener sleeps outside direct
      modes and survives compositor and greetd session replacement.
    '';
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
          screenPreferences = ["all"];
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

  kdeConnectScrollIntervalMs = lib.mkOption {
    type = lib.types.ints.between 0 1000;
    default = kdeConnectInputDefaults.scrollIntervalMs;
    description = ''
      Minimum interval between KDE Connect XTest wheel steps in
      milliseconds. Zero preserves upstream packet-for-packet scrolling.
    '';
  };

  kdeConnectPointerSensitivity = lib.mkOption {
    type = lib.types.numbers.positive;
    default = kdeConnectInputDefaults.pointerSensitivity;
    description = "Maximum KDE Connect pointer gain during fast motion.";
  };

  kdeConnectPointerPrecisionSensitivity = lib.mkOption {
    type = lib.types.numbers.positive;
    default = kdeConnectInputDefaults.pointerPrecisionSensitivity;
    description = "KDE Connect pointer gain during slow, precise motion.";
  };

  kdeConnectPointerAccelerationStart = lib.mkOption {
    type = lib.types.numbers.nonnegative;
    default = kdeConnectInputDefaults.pointerAccelerationStart;
    description = "Pointer speed where KDE Connect acceleration starts.";
  };

  kdeConnectPointerAccelerationFull = lib.mkOption {
    type = lib.types.numbers.positive;
    default = kdeConnectInputDefaults.pointerAccelerationFull;
    description = "Pointer speed where KDE Connect reaches maximum gain.";
  };

  keyboardLayouts = lib.mkOption {
    type = lib.types.str;
    default = "us,no";
    description = "Comma-separated XKB layouts used by the dedicated couch session, in default-first order.";
  };

  keyboardLayoutDeviceOverrides = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf lib.types.str);
    default = {};
    description = ''
      Case-insensitive keyboard-name substrings that select a layout for a
      streamed browser when the matching device is connected. Attribute
      names are layout identifiers from keyboardLayouts.
    '';
  };

  keyboardOptions = lib.mkOption {
    type = lib.types.str;
    default = "grp:alt_shift_toggle";
    description = "XKB options used by the dedicated couch session.";
  };

  cursorThemePackage = lib.mkOption {
    type = lib.types.nullOr lib.types.package;
    default = null;
    description = "Optional XCursor theme package installed for the dedicated couch session.";
  };

  cursorTheme = lib.mkOption {
    type = lib.types.str;
    default = "default";
    description = "XCursor theme name used by the dedicated couch session.";
  };

  cursorSize = lib.mkOption {
    type = lib.types.ints.positive;
    default = 24;
    description = "Cursor size in pixels used by the dedicated couch session.";
  };

  remotePointerInactiveTimeout = lib.mkOption {
    type = lib.types.ints.between 0 20;
    default = kdeConnectInputDefaults.cursorInactiveTimeoutSeconds;
    description = ''
      Seconds to retain the couch cursor after remote pointer activity.
      Zero disables inactivity hiding.
    '';
  };

  browserPackage = lib.mkOption {
    type = lib.types.package;
    default = pkgs.helium;
    defaultText = lib.literalExpression "pkgs.helium";
    description = "Browser package used by the couch browser launcher.";
  };

  enableLocalBrowser = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Install and expose the local browser fallback in the dedicated session.";
  };

  enableLocalUtilities = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Install and expose local couch-session utilities such as the terminal launcher.";
  };

  browserScaleFactor = lib.mkOption {
    type = lib.types.float;
    default = 1.0;
    description = "Chromium device scale factor used by couch browser launchers.";
  };

  browserPresentationScale = lib.mkOption {
    type = lib.types.float;
    default = 1.0;
    description = ''
      UI and cursor presentation class requested from a remote browser
      capsule. This does not change streamed video resolution.
    '';
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
      "direct-browser"
      "merged"
    ];
    default = "couch";
    description = ''
      Session mode initialized on activation and boot. Direct browser mode
      persistently starts the public browser with Moonlight owning DRM;
      other direct modes remain one-shot requests.
    '';
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

  enableAudioHealthRecovery = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Reconcile vanished couch audio routes and recover an unresponsive
      graph by reconnecting active local Moonlight clients.
    '';
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
    default = ["1920x1080@60"];
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
}
