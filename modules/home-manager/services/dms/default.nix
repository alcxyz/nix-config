# modules/home-manager/services/dms/default.nix
{ lib, config, inputs, pkgs, username, ... }:

let
  cfg = config.services.dms;
  plugins = inputs.dms-plugins.srcs;
  dankcalendarPkg = inputs.DankCalendar.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  options.services.dms.enable =
    lib.mkEnableOption "Enable DankMaterialShell suite";

  imports = [
    inputs.dsearch.homeModules.default
    inputs.dankMaterialShell.homeModules.dank-material-shell
  ];

  config = lib.mkIf cfg.enable {
    home.packages = [ dankcalendarPkg ];

    xdg.configFile."DankMaterialShell/plugin_settings.json".source =
      config.lib.file.mkOutOfStoreSymlink
        "${config.home.homeDirectory}/nix/nix-config/users/${username}/configs/dms/plugin_settings.json";

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
          src = inputs.DankCalendar;
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
  };
}
