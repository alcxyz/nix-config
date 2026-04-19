# modules/home-manager/services/dms/default.nix
{ lib, config, inputs, pkgs, username, ... }:

let
  cfg = config.services.dms;
in
{
  options.services.dms.enable =
    lib.mkEnableOption "Enable DankMaterialShell suite";

  imports = [
    inputs.dsearch.homeModules.default
    inputs.dankMaterialShell.homeModules.dank-material-shell
  ];

  config = lib.mkIf cfg.enable {
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
          src = inputs.dms-plugin-worldclock;
        };
        DankCalculator = {
          enable = true;
          src = inputs.dms-plugin-calculator;
        };
      };
    };
  };
}
