# users/alc/linux/rpi0.nix
{
  configDir,
  pkgs,
  username,
  ...
}: {
  imports = [
    # Keep the option schema available for shared conditional defaults without
    # enabling or installing the operator Kubernetes toolchain.
    "${configDir}/modules/home-manager/programs/kubernetes/default.nix"
    "${configDir}/modules/home-manager/services/dms/default.nix"
    "${configDir}/modules/home-manager/services/waynergy/default.nix"
  ];

  # This is an appliance profile, not the shared Linux operator profile.
  # Runtime dependencies for DMS and Waynergy are owned by their modules;
  # retain only a small set of tools useful for local recovery and input/audio
  # diagnostics.
  home = {
    inherit username;
    homeDirectory = "/home/${username}";
    stateVersion = "24.11";
    packages = with pkgs; [
      bluetuith
      btop
      jq
      ripgrep
      wl-clipboard
    ];
  };

  programs.home-manager.enable = true;
  colorscheme.name = "catppuccin-mocha";

  services.dms = {
    enable = true;
    profile = "compact";
    pluginSettingsFile = null;
    dock = {
      enable = true;
      autoHide = true;
    };
    polkitDialog = {
      width = 760;
      height = 460;
    };
    settings = {
      customPowerActionReboot = "couch-session-power-action reboot";
      customPowerActionPowerOff = "couch-session-power-action poweroff";
    };
  };

  services.waynergy = {
    enable = true;
    screenName = "rpi0";
    sourceKeyboard = "mac";
    backend = "uinput";
    requireLanAddress = true;
    useFocusedMonitorGeometry = true;
  };
}
