# modules/home-manager/suites/dms/default.nix
{ lib, config, inputs, pkgs-unstable, ... }:

let
  cfg = config.suites.dms;
in
{
  options.suites.dms = {
    enable = lib.mkEnableOption "Enable DankMaterialShell suite";
  };

  # imports MUST NOT depend on config; import DMS always
  imports = [
    inputs.dankMaterialShell.homeModules.dankMaterialShell.default
  ];

  # Gate all actual config behind cfg.enable
  config = lib.mkIf cfg.enable {
    programs.dankMaterialShell = {
      enable = true;

      # Ensure systemd user service is used (auto-start DMS)
      systemd.enable = true;
      systemd.restartIfChanged = true;

      # Use unstable Quickshell
      quickshell.package = pkgs-unstable.quickshell;

      # Optional: feature toggles
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
