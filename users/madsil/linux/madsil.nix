# users/madsil/linux/madsil.nix
{
  config,
  configDir,
  inputs,
  pkgs,
  ...
}: {
  imports = [
    inputs.nix-colors.homeManagerModules.default
    "${configDir}/modules/home-manager/programs/wayland-common/default.nix"
    "${configDir}/modules/home-manager/programs/hyprland/default.nix"
    "${configDir}/modules/home-manager/services/dms/default.nix"
    "${configDir}/modules/home-manager/services/hyprlock/default.nix"
    "${configDir}/modules/home-manager/programs/foot/default.nix"
  ];

  home.username = "madsil";
  home.homeDirectory = "/home/madsil";
  home.stateVersion = "24.11";

  colorscheme.name = "catppuccin-mocha";

  home.packages = with pkgs; [
    nautilus
    wl-clipboard
  ];

  home.sessionVariables = {
    NIXOS_OZONE_WL = "1";
  };

  programs.foot.enable = true;
  programs.hyprland.managed = {
    enable = true;
    inputSensitivity = 0.0;
  };

  services.dms = {
    enable = true;
    dock = {
      enable = true;
      autoHide = true;
    };
    idleLock = {
      enable = true;
      command = config.services.hyprlock.lockCommand;
      acTimeout = 1800;
      batteryTimeout = 1800;
    };
  };

  services.hyprlock.enable = true;
}
