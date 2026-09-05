# modules/home-manager/services/dms/default.nix
{
  lib,
  config,
  inputs,
  pkgs,
  username,
  configDir,
  ...
}: let
  cfg = config.services.dms;
  compact = cfg.profile == "compact";
  idleLockCfg = cfg.idleLock;
  dockCfg = cfg.dock;
  optionalSetting = name: value:
    lib.optionalAttrs (value != null) {
      ${name} = value;
    };
  idleLockSettings =
    {
      acLockTimeout = idleLockCfg.acTimeout;
      batteryLockTimeout = idleLockCfg.batteryTimeout;
      customPowerActionLock = idleLockCfg.command;
      fadeToLockEnabled = idleLockCfg.fadeToLock;
    }
    // optionalSetting "acMonitorTimeout" idleLockCfg.acMonitorTimeout
    // optionalSetting "batteryMonitorTimeout" idleLockCfg.batteryMonitorTimeout
    // optionalSetting "acSuspendTimeout" idleLockCfg.acSuspendTimeout
    // optionalSetting "batterySuspendTimeout" idleLockCfg.batterySuspendTimeout
    // optionalSetting "acPostLockMonitorTimeout" idleLockCfg.acPostLockMonitorTimeout
    // optionalSetting "batteryPostLockMonitorTimeout" idleLockCfg.batteryPostLockMonitorTimeout
    // optionalSetting "fadeToLockGracePeriod" idleLockCfg.fadeToLockGracePeriod
    // optionalSetting "fadeToDpmsEnabled" idleLockCfg.fadeToDpms
    // optionalSetting "fadeToDpmsGracePeriod" idleLockCfg.fadeToDpmsGracePeriod
    // lib.optionalAttrs idleLockCfg.disableLoginctlIntegration {
      loginctlLockIntegration = false;
      lockBeforeSuspend = false;
    };
  compactSettings = lib.optionalAttrs compact {
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
    fontScale = 1.5;
    showDock = true;
    dockAutoHide = true;
    dockSmartAutoHide = true;
    notificationOverlayEnabled = false;
    barConfigs = [
      {
        id = "nixbox";
        name = "Nixbox";
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
          "systemTray"
          "notificationButton"
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
  generatedSettings = lib.recursiveUpdate compactSettings (
    lib.recursiveUpdate (lib.optionalAttrs idleLockCfg.enable idleLockSettings) (
      lib.optionalAttrs dockCfg.enable {
        showDock = true;
        dockAutoHide = dockCfg.autoHide;
      }
    )
  );
  managedSettings = lib.recursiveUpdate generatedSettings cfg.settings;
  managedSettingsFile = pkgs.writeText "dms-managed-settings.json" (builtins.toJSON managedSettings);
  basePluginSettings =
    if cfg.pluginSettingsFile == null || !(builtins.pathExists cfg.pluginSettingsFile)
    then {}
    else builtins.fromJSON (builtins.readFile cfg.pluginSettingsFile);
  managedPluginSettings = lib.recursiveUpdate basePluginSettings cfg.pluginSettings;
  managedPluginSettingsFile = pkgs.writeText "dms-managed-plugin-settings.json" (
    builtins.toJSON managedPluginSettings
  );
  elevationPkg = pkgs.writeShellApplication {
    name = "dms-elevate";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      usage() {
        echo "Usage: dms-elevate --title TITLE --reason REASON [--impact IMPACT] [--command-label LABEL] -- COMMAND [ARG ...]" >&2
        exit 2
      }

      if [[ ''${1:-} == "--execute" ]]; then
        shift
        [[ ''${1:-} == "--request-id" && -n ''${2:-} ]] || usage
        shift 2
        [[ ''${1:-} == "--" ]] || usage
        shift
        (( $# > 0 )) || usage
        [[ $(id -u) -eq 0 ]] || {
          echo "dms-elevate: the executor must be started through Polkit" >&2
          exit 1
        }
        exec "$@"
      fi

      title=""
      reason=""
      impact=""
      command_label=""
      while (( $# > 0 )); do
        case "$1" in
          --title)
            [[ -n ''${2:-} ]] || usage
            title="$2"
            shift 2
            ;;
          --reason)
            [[ -n ''${2:-} ]] || usage
            reason="$2"
            shift 2
            ;;
          --impact)
            [[ -n ''${2:-} ]] || usage
            impact="$2"
            shift 2
            ;;
          --command-label)
            [[ -n ''${2:-} ]] || usage
            command_label="$2"
            shift 2
            ;;
          --)
            shift
            break
            ;;
          *) usage ;;
        esac
      done

      [[ -n "$title" && -n "$reason" ]] || usage
      (( $# > 0 )) || usage
      [[ -n ''${XDG_RUNTIME_DIR:-} && -d "$XDG_RUNTIME_DIR" ]] || {
        echo "dms-elevate: XDG_RUNTIME_DIR is unavailable" >&2
        exit 1
      }

      request_id="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
      context_file="$XDG_RUNTIME_DIR/dms-elevation-context.json"
      context_tmp="$(mktemp "$XDG_RUNTIME_DIR/.dms-elevation-context.XXXXXX")"
      self="$(readlink -f "$0")"
      umask 077

      cleanup() {
        rm -f "$context_tmp"
        if [[ -f "$context_file" ]] && [[ "$(jq -r '.requestId // empty' "$context_file" 2>/dev/null)" == "$request_id" ]]; then
          rm -f "$context_file"
        fi
      }
      trap cleanup EXIT HUP INT TERM

      jq -n \
        --arg title "$title" \
        --arg reason "$reason" \
        --arg impact "$impact" \
        --arg commandLabel "$command_label" \
        --arg requestId "$request_id" \
        --argjson createdAt "$(date +%s%3N)" \
        '{title: $title, reason: $reason, impact: $impact, commandLabel: $commandLabel, requestId: $requestId, createdAt: $createdAt}' \
        > "$context_tmp"
      chmod 0600 "$context_tmp"
      mv -f "$context_tmp" "$context_file"

      pkexec_path="/run/wrappers/bin/pkexec"
      if [[ ! -x "$pkexec_path" ]]; then
        pkexec_path="$(command -v pkexec || true)"
      fi
      [[ -n "$pkexec_path" ]] || {
        echo "dms-elevate: pkexec is unavailable" >&2
        exit 1
      }

      "$pkexec_path" "$self" --execute --request-id "$request_id" -- "$@"
    '';
  };
  mergeJsonInto = targetFile: managedFile: ''
    settings_file="${targetFile}"
    settings_tmp="$settings_file.tmp"

    mkdir -p "$(${pkgs.coreutils}/bin/dirname "$settings_file")"

    if [ -e "$settings_file" ] && ${pkgs.jq}/bin/jq -e . "$settings_file" >/dev/null 2>&1 && ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$settings_file" "${managedFile}" > "$settings_tmp"; then
      mv "$settings_tmp" "$settings_file"
    else
      rm -f "$settings_file"
      cp "${managedFile}" "$settings_file"
      rm -f "$settings_tmp"
    fi
    chmod 0644 "$settings_file"
  '';
  plugins = inputs.dms-plugins.srcs;
  dsearchPkg = inputs.dsearch.packages.${pkgs.stdenv.hostPlatform.system}.dsearch;
  dankcalendarPkg = pkgs.callPackage "${plugins.dankcalendar}/default.nix" {
    version = (builtins.fromJSON (builtins.readFile "${plugins.dankcalendar}/plugin.json")).version;
  };
  dankaiusagePkg = pkgs.callPackage "${plugins.aiusage}/default.nix" {
    version = (builtins.fromJSON (builtins.readFile "${plugins.aiusage}/plugin.json")).version;
  };
  danksessionPkg = inputs.danksession.packages.${pkgs.stdenv.hostPlatform.system}.danksession;
  quickshellBasePkg = inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default;
  quickshellUnwrappedPkg = quickshellBasePkg.unwrapped.overrideAttrs (old: {
    patches =
      (old.patches or [])
      ++ [
        ./patches/quickshell-polkit-details.patch
      ];
  });
  quickshellPkg = quickshellBasePkg.overrideAttrs (_: {
    installPhase = ''
      mkdir -p "$out"
      cp -r ${quickshellUnwrappedPkg}/* "$out"
    '';
    passthru =
      (quickshellBasePkg.passthru or {})
      // {
        unwrapped = quickshellUnwrappedPkg;
      };
  });
  dmsPkg =
    inputs.dankMaterialShell.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs
    (old: {
      patches =
        (old.patches or [])
        ++ [
          ./patches/dms-cleanup-hyprland-conf-only-in-lua-session.patch
        ];
      postInstall =
        (old.postInstall or "")
        + ''
          # DMS is launched by the compositor so its lifetime and resume
          # watcher share the real Hyprland session. Do not expose upstream's
          # user service: activation tools can otherwise start a competing
          # DMS instance even though the Home Manager systemd option is off.
          rm -f \
            "$out/lib/systemd/user/dms.service" \
            "$out/share/systemd/user/dms.service"
          chmod -R u+w "$out/share/quickshell/dms"
          patch -d "$out/share/quickshell/dms" -p2 < ${./patches/dms-use-live-hyprland-provider.patch}
          patch -d "$out/share/quickshell/dms" -p2 < ${./patches/dms-focused-polkit-surface.patch}
          patch -d "$out/share/quickshell/dms" -p2 < ${./patches/dms-configurable-external-idle-inhibitors.patch}
          substituteInPlace "$out/share/quickshell/dms/Services/IdleService.qml" \
            --subst-var-by respectExternalInhibitors ${lib.boolToString cfg.idleLock.respectExternalInhibitors}
          substituteInPlace "$out/share/quickshell/dms/Modals/PolkitAuthSurfaceModal.qml" \
            --subst-var-by polkitModalWidth ${toString cfg.polkitDialog.width} \
            --subst-var-by polkitModalHeight ${toString cfg.polkitDialog.height}
          ${lib.optionalString (cfg.audioOutputCommand != null) ''
            patch -d "$out/share/quickshell/dms" -p2 < ${./patches/dms-external-audio-output.patch}
            substituteInPlace "$out/share/quickshell/dms/Services/AudioService.qml" \
              --subst-var-by audioOutputCommand ${lib.escapeShellArg cfg.audioOutputCommand}
          ''}
        '';
    });
  autoDoNotDisturbCfg = cfg.autoDoNotDisturb;
  autoDoNotDisturbMatchers = builtins.toJSON autoDoNotDisturbCfg.windowMatchers;
  autoDoNotDisturbWatcher = pkgs.writeShellApplication {
    name = "dms-auto-do-not-disturb";
    runtimeInputs = [
      dmsPkg
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
      pkgs.netcat-openbsd
    ];
    text = ''
      matchers=${lib.escapeShellArg autoDoNotDisturbMatchers}
      owned_marker="''${XDG_RUNTIME_DIR:?}/dms-auto-do-not-disturb.owned"
      socket="''${XDG_RUNTIME_DIR:?}/hypr/''${HYPRLAND_INSTANCE_SIGNATURE:?}/.socket2.sock"
      matching=false

      has_matching_window() {
        hyprctl clients -j 2>/dev/null \
          | jq -e --argjson matchers "$matchers" '
              any(.[]; . as $window |
                any($matchers[]; . as $matcher |
                  (($matcher.classRegex == null)
                    or (($window.class // "") | test($matcher.classRegex)))
                  and (($matcher.titleRegex == null)
                    or (($window.title // "") | test($matcher.titleRegex)))
                  and (($matcher.initialClassRegex == null)
                    or (($window.initialClass // "") | test($matcher.initialClassRegex)))
                  and (($matcher.initialTitleRegex == null)
                    or (($window.initialTitle // "") | test($matcher.initialTitleRegex)))
                )
              )
            ' >/dev/null
      }

      dnd_is_enabled() {
        [[ "$(dms ipc call notifications getDoNotDisturb 2>/dev/null || true)" == true ]]
      }

      enable_owned_dnd() {
        if dms ipc call notifications enableDoNotDisturbIndefinitely >/dev/null 2>&1; then
          touch "$owned_marker"
          return 0
        fi
        return 1
      }

      release_owned_dnd() {
        if [[ -e "$owned_marker" ]]; then
          if dnd_is_enabled; then
            dms ipc call notifications disableDoNotDisturb >/dev/null 2>&1 \
              || return 1
          fi
          rm -f "$owned_marker"
        fi
      }

      trap 'release_owned_dnd || true' EXIT
      trap 'exit 0' HUP INT TERM

      sync_dnd() {
        if has_matching_window; then
          if [[ "$matching" != true ]]; then
            if dnd_is_enabled; then
              matching=true
            elif enable_owned_dnd; then
              matching=true
            fi
          fi
        else
          release_owned_dnd
          matching=false
        fi
      }

      sync_dnd
      while true; do
        while IFS= read -r event; do
          case "$event" in
            openwindow\>\>* | openwindowv2\>\>* \
              | closewindow\>\>* | closewindowv2\>\>* \
              | windowtitle\>\>* | windowtitlev2\>\>*)
              # Let Hyprland finish updating its client list before evaluating.
              sleep 0.05
              sync_dnd
              ;;
          esac
        done < <(timeout 5 nc -U "$socket" 2>/dev/null || true)
        sleep 1
        sync_dnd
      done
    '';
  };
in {
  options.services.dms = {
    enable = lib.mkEnableOption "Enable DankMaterialShell suite";

    profile = lib.mkOption {
      type = lib.types.enum [
        "full"
        "compact"
      ];
      default = "full";
      description = "DMS feature profile; compact keeps only the core shell surfaces.";
    };

    audioOutputCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional output-selection command. DMS invokes it with
        `select-name NODE_NAME` instead of changing the PipeWire default
        through its in-process node object.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "DMS settings.json keys to manage declaratively. These override generated settings for the same keys.";
    };

    pluginSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "DMS plugin_settings.json keys to manage declaratively. These override the base plugin settings file for the same keys.";
    };

    pluginSettingsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "${configDir}/users/${username}/configs/dms/plugin_settings.json";
      description = "Optional base plugin_settings.json file to merge before services.dms.pluginSettings.";
    };

    dankSession = {
      enable = lib.mkEnableOption "Install DankSession for pre-release QA";

      autoStart = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Start the DankSession capture daemon with the graphical session. Keep disabled during manual QA.";
      };
    };

    autoDoNotDisturb = {
      enable = lib.mkEnableOption "Automatically enable DMS Do Not Disturb while matching Hyprland applications are running";

      windowMatchers = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              classRegex = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Regular expression matched against the current window class.";
              };

              titleRegex = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Regular expression matched against the current window title.";
              };

              initialClassRegex = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Regular expression matched against the initial window class.";
              };

              initialTitleRegex = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Regular expression matched against the initial window title.";
              };
            };
          }
        );
        default = [];
        description = "Hyprland window matchers that activate DMS Do Not Disturb while at least one matching window exists.";
      };
    };

    idleLock = {
      enable = lib.mkEnableOption "Use DMS idle detection to invoke an external locker";

      command = lib.mkOption {
        type = lib.types.str;
        default = "lock-screen";
        description = "External command DMS should run when its idle lock timeout fires.";
      };

      acTimeout = lib.mkOption {
        type = lib.types.int;
        default = 300;
        description = "AC power idle lock timeout in seconds.";
      };

      batteryTimeout = lib.mkOption {
        type = lib.types.int;
        default = 300;
        description = "Battery power idle lock timeout in seconds.";
      };

      respectExternalInhibitors = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether application idle inhibitors may suppress DMS lock, monitor-off, and suspend timers.";
      };

      acMonitorTimeout = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "AC power monitor-off timeout in seconds. Null leaves the DMS value unmanaged.";
      };

      batteryMonitorTimeout = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Battery power monitor-off timeout in seconds. Null leaves the DMS value unmanaged.";
      };

      acSuspendTimeout = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "AC power suspend timeout in seconds. Null leaves the DMS value unmanaged.";
      };

      batterySuspendTimeout = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Battery power suspend timeout in seconds. Null leaves the DMS value unmanaged.";
      };

      acPostLockMonitorTimeout = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "AC power monitor-off timeout after the DMS lock state is active. Null leaves the DMS value unmanaged.";
      };

      batteryPostLockMonitorTimeout = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Battery power monitor-off timeout after the DMS lock state is active. Null leaves the DMS value unmanaged.";
      };

      disableLoginctlIntegration = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Disable DMS loginctl lock integration when an external locker owns locking.";
      };

      fadeToLock = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether DMS should show its fade-to-lock transition before invoking the external locker.";
      };

      fadeToLockGracePeriod = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "DMS fade-to-lock grace period in seconds. Null leaves the DMS value unmanaged.";
      };

      fadeToDpms = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether DMS should show its fade-to-DPMS transition before turning monitors off. Null leaves the DMS value unmanaged.";
      };

      fadeToDpmsGracePeriod = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "DMS fade-to-DPMS grace period in seconds. Null leaves the DMS value unmanaged.";
      };
    };

    dock = {
      enable = lib.mkEnableOption "Show the DMS dock";

      autoHide = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether the DMS dock should auto-hide.";
      };
    };

    polkitDialog = {
      width = lib.mkOption {
        type = lib.types.ints.positive;
        default = 560;
        description = "Width of the focused-screen DMS authorization surface.";
      };

      height = lib.mkOption {
        type = lib.types.ints.positive;
        default = 340;
        description = "Height of the focused-screen DMS authorization surface.";
      };
    };
  };

  imports = [
    inputs.dsearch.homeModules.default
    inputs.dankMaterialShell.homeModules.dank-material-shell
    inputs.danksession.homeManagerModules.default
  ];

  config = lib.mkIf cfg.enable {
    assertions = lib.optional autoDoNotDisturbCfg.enable {
      assertion =
        autoDoNotDisturbCfg.windowMatchers
        != []
        && lib.all (
          matcher:
            lib.any (field: matcher.${field} != null) [
              "classRegex"
              "titleRegex"
              "initialClassRegex"
              "initialTitleRegex"
            ]
        )
        autoDoNotDisturbCfg.windowMatchers;
      message = "services.dms.autoDoNotDisturb requires at least one non-empty Hyprland window matcher.";
    };

    home.packages =
      [
        elevationPkg
      ]
      ++ lib.optionals (!compact) [
        dankcalendarPkg
        dankaiusagePkg
        pkgs.translate-shell
      ];

    xdg.configFile = lib.optionalAttrs (!compact) {
      "dankcalendar/config.json".source =
        config.lib.file.mkOutOfStoreSymlink "${configDir}/users/${username}/configs/dankcalendar/config.json";
    };

    programs.dsearch = {
      enable = true;
      package = dsearchPkg;
    };

    services.dankSession = lib.mkIf cfg.dankSession.enable {
      enable = true;
      package = danksessionPkg;
      autoStart = cfg.dankSession.autoStart;
    };

    programs.dank-material-shell = {
      enable = true;
      package = dmsPkg;

      quickshell.package = quickshellPkg;

      systemd = {
        enable = false;
        restartIfChanged = true;
      };

      enableSystemMonitoring = !compact;
      enableVPN = !compact;
      enableDynamicTheming = !compact;
      enableAudioWavelength = !compact;
      enableCalendarEvents = !compact;

      plugins = {
        WorldClock = {
          enable = !compact;
          src = plugins.worldclock;
        };
        DankCalculator = {
          enable = !compact;
          src = plugins.calculator;
        };
        dmsScreenshot = {
          enable = !compact;
          src = plugins.screenshot;
        };
        DankQuickSearch = {
          enable = !compact;
          src = plugins.quicksearch;
        };
        DankVault = {
          enable = !compact;
          src = plugins.vault;
        };
        DankTranslate = {
          enable = !compact;
          src = plugins.translate;
        };
        DankSpotify = {
          enable = !compact;
          src = plugins.spotify;
        };
        DankCalendar = {
          enable = !compact;
          src = plugins.dankcalendar;
        };
        DankSession = {
          enable = !compact && cfg.dankSession.enable;
          src = inputs.danksession;
        };
        DankDiskUsage = {
          enable = !compact;
          src = plugins.diskusage;
        };
        DankAIUsage = {
          enable = !compact;
          src = plugins.aiusage;
        };
        DankDisplayControl = {
          enable = !compact;
          src = plugins.displaycontrol;
        };
        # First-party plugins (AvengeMedia/dms-plugins monorepo)
        DankActions = {
          enable = !compact;
          src = plugins.firstparty + "/DankActions";
        };
        DankBatteryAlerts = {
          enable = !compact;
          src = plugins.firstparty + "/DankBatteryAlerts";
        };
        DankClight = {
          enable = !compact;
          src = plugins.firstparty + "/DankClight";
        };
        DankDesktopWeather = {
          enable = !compact;
          src = plugins.firstparty + "/DankDesktopWeather";
        };
        DankGifSearch = {
          enable = !compact;
          src = plugins.firstparty + "/DankGifSearch";
        };
        DankHooks = {
          enable = !compact;
          src = plugins.firstparty + "/DankHooks";
        };
        DankHyprlandWindows = {
          enable = !compact;
          src = plugins.firstparty + "/DankHyprlandWindows";
        };
        DankKDEConnect = {
          enable = !compact;
          src = plugins.firstparty + "/DankKDEConnect";
        };
        DankLauncherKeys = {
          enable = !compact;
          src = plugins.firstparty + "/DankLauncherKeys";
        };
        DankNotepadModule = {
          enable = !compact;
          src = plugins.firstparty + "/DankNotepadModule";
        };
        DankPomodoroTimer = {
          enable = !compact;
          src = plugins.firstparty + "/DankPomodoroTimer";
        };
        DankStickerSearch = {
          enable = !compact;
          src = plugins.firstparty + "/DankStickerSearch";
        };
      };
    };

    systemd.user.services.dms-auto-do-not-disturb = lib.mkIf autoDoNotDisturbCfg.enable {
      Unit = {
        Description = "Toggle DMS Do Not Disturb for configured Hyprland applications";
        BindsTo = ["wayland-wm@hyprland.desktop.service"];
        After = ["wayland-wm@hyprland.desktop.service"];
      };
      Service = {
        ExecStart = lib.getExe autoDoNotDisturbWatcher;
        Restart = "always";
        RestartSec = 1;
      };
      Install.WantedBy = ["wayland-wm@hyprland.desktop.service"];
    };

    home.activation.dmsManagedSettings = lib.mkIf (managedSettings != {}) (
      lib.hm.dag.entryAfter ["writeBoundary"] ''
        ${mergeJsonInto "${config.xdg.configHome}/DankMaterialShell/settings.json" managedSettingsFile}
      ''
    );

    home.activation.dmsManagedPluginSettings = lib.mkIf (managedPluginSettings != {}) (
      lib.hm.dag.entryAfter ["linkGeneration"] ''
        ${mergeJsonInto "${config.xdg.configHome}/DankMaterialShell/plugin_settings.json" managedPluginSettingsFile}
      ''
    );
  };
}
