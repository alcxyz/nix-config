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
  generatedSettings =
    lib.recursiveUpdate
    (lib.optionalAttrs idleLockCfg.enable idleLockSettings)
    (lib.optionalAttrs dockCfg.enable {
      showDock = true;
      dockAutoHide = dockCfg.autoHide;
    });
  managedSettings = lib.recursiveUpdate generatedSettings cfg.settings;
  managedSettingsFile = pkgs.writeText "dms-managed-settings.json" (
    builtins.toJSON managedSettings
  );
  basePluginSettings =
    if cfg.pluginSettingsFile == null || !(builtins.pathExists cfg.pluginSettingsFile)
    then {}
    else builtins.fromJSON (builtins.readFile cfg.pluginSettingsFile);
  managedPluginSettings = lib.recursiveUpdate basePluginSettings cfg.pluginSettings;
  managedPluginSettingsFile = pkgs.writeText "dms-managed-plugin-settings.json" (
    builtins.toJSON managedPluginSettings
  );
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
  dsearchPkg = inputs.dsearch.packages.${pkgs.stdenv.hostPlatform.system}.dsearch.overrideAttrs {
    vendorHash = "sha256-scvZWbMHAhpYWCU0xZK1E6h6sAkoXegqI1iYS44fcCg=";
  };
  dankcalendarPkg = pkgs.callPackage "${plugins.dankcalendar}/default.nix" {
    version = (builtins.fromJSON (builtins.readFile "${plugins.dankcalendar}/plugin.json")).version;
  };
  dankaiusagePkg = pkgs.callPackage "${plugins.aiusage}/default.nix" {
    version = (builtins.fromJSON (builtins.readFile "${plugins.aiusage}/plugin.json")).version;
  };
in {
  options.services.dms = {
    enable = lib.mkEnableOption "Enable DankMaterialShell suite";

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
  };

  imports = [
    inputs.dsearch.homeModules.default
    inputs.dankMaterialShell.homeModules.dank-material-shell
  ];

  config = lib.mkIf cfg.enable {
    home.packages = [
      dankcalendarPkg
      dankaiusagePkg
      pkgs.translate-shell
    ];

    xdg.configFile."dankcalendar/config.json".source =
      config.lib.file.mkOutOfStoreSymlink "${configDir}/users/${username}/configs/dankcalendar/config.json";

    programs.dsearch = {
      enable = true;
      package = dsearchPkg;
    };

    programs.dank-material-shell = {
      enable = true;

      #quickshell.package = pkgs.quickshell;
      quickshell.package = inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default;

      systemd = {
        enable = false;
        restartIfChanged = true;
      };

      enableSystemMonitoring = true;
      enableVPN = true;
      enableDynamicTheming = true;
      enableAudioWavelength = true;
      enableCalendarEvents = true;

      plugins = {
        WorldClock = {
          enable = true;
          src = plugins.worldclock;
        };
        DankCalculator = {
          enable = true;
          src = plugins.calculator;
        };
        DankQuickSearch = {
          enable = true;
          src = plugins.quicksearch;
        };
        DankVault = {
          enable = true;
          src = plugins.vault;
        };
        DankTranslate = {
          enable = true;
          src = plugins.translate;
        };
        DankSpotify = {
          enable = true;
          src = plugins.spotify;
        };
        DankCalendar = {
          enable = true;
          src = plugins.dankcalendar;
        };
        DankDiskUsage = {
          enable = true;
          src = plugins.diskusage;
        };
        DankAIUsage = {
          enable = true;
          src = plugins.aiusage;
        };
        # First-party plugins (AvengeMedia/dms-plugins monorepo)
        DankActions = {
          enable = true;
          src = plugins.firstparty + "/DankActions";
        };
        DankBatteryAlerts = {
          enable = true;
          src = plugins.firstparty + "/DankBatteryAlerts";
        };
        DankClight = {
          enable = true;
          src = plugins.firstparty + "/DankClight";
        };
        DankDesktopWeather = {
          enable = true;
          src = plugins.firstparty + "/DankDesktopWeather";
        };
        DankGifSearch = {
          enable = true;
          src = plugins.firstparty + "/DankGifSearch";
        };
        DankHooks = {
          enable = true;
          src = plugins.firstparty + "/DankHooks";
        };
        DankHyprlandWindows = {
          enable = true;
          src = plugins.firstparty + "/DankHyprlandWindows";
        };
        DankKDEConnect = {
          enable = true;
          src = plugins.firstparty + "/DankKDEConnect";
        };
        DankLauncherKeys = {
          enable = true;
          src = plugins.firstparty + "/DankLauncherKeys";
        };
        DankNotepadModule = {
          enable = true;
          src = plugins.firstparty + "/DankNotepadModule";
        };
        DankPomodoroTimer = {
          enable = true;
          src = plugins.firstparty + "/DankPomodoroTimer";
        };
        DankStickerSearch = {
          enable = true;
          src = plugins.firstparty + "/DankStickerSearch";
        };
      };
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
