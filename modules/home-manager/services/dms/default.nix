# modules/home-manager/suites/dms/default.nix
{ lib, config, inputs, pkgs, ... }:

let
  cfg = config.suites.dms;
in
{
  options.suites.dms.enable =
    lib.mkEnableOption "Enable DankMaterialShell suite";

  imports = [
    inputs.dsearch.homeModules.default
    inputs.dankMaterialShell.homeModules.dankMaterialShell.default
  ];

  config = lib.mkIf cfg.enable {
    programs.dsearch = {
      enable = true;
    };

    programs.dankMaterialShell = {
      enable = true;

      #quickshell.package = pkgs.quickshell;
      quickshell.package = inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default;

      systemd = {
        enable = false;
        restartIfChanged = true;
      };

      enableSystemMonitoring = true;
      enableClipboard = true;
      enableVPN = true;
      enableBrightnessControl = false;
      enableColorPicker = true;
      enableDynamicTheming = true;
      enableAudioWavelength = true;
      enableCalendarEvents = true;
      enableSystemSound = true;

      plugins = {
        WorldClock = {
          enable = true;
          src = plugins/WorldClock;
        };
      };
    };
  };
}
