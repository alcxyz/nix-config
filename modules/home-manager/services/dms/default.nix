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
  idleLockSettings =
    {
      acLockTimeout = idleLockCfg.acTimeout;
      batteryLockTimeout = idleLockCfg.batteryTimeout;
      customPowerActionLock = idleLockCfg.command;
      fadeToLockEnabled = idleLockCfg.fadeToLock;
    }
    // lib.optionalAttrs idleLockCfg.disableLoginctlIntegration {
      loginctlLockIntegration = false;
      lockBeforeSuspend = false;
    };
  managedSettings =
    lib.optionalAttrs idleLockCfg.enable idleLockSettings
    // lib.optionalAttrs dockCfg.enable {
      showDock = true;
      dockAutoHide = dockCfg.autoHide;
    };
  managedSettingsFile = pkgs.writeText "dms-managed-settings.json" (
    builtins.toJSON managedSettings
  );
  plugins = inputs.dms-plugins.srcs;
  dankcalendarPkg = pkgs.callPackage "${plugins.dankcalendar}/default.nix" {
    version = (builtins.fromJSON (builtins.readFile "${plugins.dankcalendar}/plugin.json")).version;
  };
in {
  options.services.dms = {
    enable = lib.mkEnableOption "Enable DankMaterialShell suite";

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
      pkgs.translate-shell
    ];

    xdg.configFile."DankMaterialShell/plugin_settings.json".source =
      config.lib.file.mkOutOfStoreSymlink "${configDir}/users/${username}/configs/dms/plugin_settings.json";

    xdg.configFile."dankcalendar/config.json".source =
      config.lib.file.mkOutOfStoreSymlink "${configDir}/users/${username}/configs/dankcalendar/config.json";

    programs.dsearch = {
      enable = true;
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
        settings_file="${config.xdg.configHome}/DankMaterialShell/settings.json"
        settings_tmp="$settings_file.tmp"

        mkdir -p "$(${pkgs.coreutils}/bin/dirname "$settings_file")"

        if [ -e "$settings_file" ] && ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$settings_file" "${managedSettingsFile}" > "$settings_tmp"; then
          mv "$settings_tmp" "$settings_file"
        else
          cp "${managedSettingsFile}" "$settings_file"
          rm -f "$settings_tmp"
        fi
      ''
    );
  };
}
