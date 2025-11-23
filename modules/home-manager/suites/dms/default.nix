# modules/home-manager/suites/dms/default.nix
{ lib, config, inputs, pkgs, ... }:

let
  cfg = config.suites.dms;
in
{
  options.suites.dms.enable =
    lib.mkEnableOption "Enable DankMaterialShell suite";

  imports = [
    inputs.dankMaterialShell.homeModules.dankMaterialShell.default
  ];

  config = lib.mkIf cfg.enable {
    programs.dankMaterialShell = {
      enable = true;

      #quickshell.package = pkgs.quickshell;

      systemd.enable = true;
      systemd.restartIfChanged = true;

      enableSystemMonitoring = true;
      enableClipboard = true;
      enableVPN = true;
      enableBrightnessControl = true;
      enableColorPicker = true;
      enableDynamicTheming = true;
      enableAudioWavelength = true;
      enableCalendarEvents = true;
      enableSystemSound = true;
    };
  };
}
