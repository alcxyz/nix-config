# users/alc/linux/xps.nix
{
  config,
  pkgs,
  lib,
  inputs,
  configDir,
  hostRole,
  ...
}: let
  pkgsets = import "${configDir}/modules/shared/pkgsets.nix" {
    inherit pkgs inputs;
  };
in {
  imports = [
    "${configDir}/users/alc/linux/common.nix"

    "${configDir}/modules/home-manager/programs/wayland-common/default.nix"
    "${configDir}/modules/home-manager/programs/hyprland/default.nix"
    "${configDir}/modules/home-manager/programs/niri/default.nix"
    "${configDir}/modules/home-manager/services/dms/default.nix"
    "${configDir}/modules/home-manager/services/hyprlock/default.nix"
    "${configDir}/modules/home-manager/programs/foot/default.nix"

    "${configDir}/modules/home-manager/programs/rclone/cloud-sync.nix"
    "${configDir}/modules/home-manager/programs/ai/default.nix"

    inputs.hyprscratch.homeModules.default
  ];

  home.packages = pkgsets.home.${hostRole.homePackageSet};

  xdg.configFile."ncspot/config.toml".source =
    config.lib.file.mkOutOfStoreSymlink "${configDir}/users/alc/configs/ncspot/config.toml";

  home.shellAliases = {
    pbcopy = "wl-copy";
    pbpaste = "wl-paste";
  };

  programs.foot.enable = true;
  programs.hyprland.managed = {
    enable = true;
    inputSensitivity = 0.0;
    laptopDisplayAutoSwitch.enable = true;
  };
  programs.niri.managed.enable = true;

  programs.hyprscratch = {
    enable = true;
    settings = {
      daemon_options = "clean";

      dropterm = {
        title = "dropterm";
        command = "foot -w 2400x1400 --app-id dropterm --title dropterm";
        rules = "float; center";
        options = "persist";
      };
    };
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
    };
  };
  services.hyprlock.enable = true;
  dconf.enable = false;
  services.udiskie = {
    enable = true;
    tray = "never";
  };
  systemd.user.services.udiskie = {
    Unit = {
      After = lib.mkForce [];
      PartOf = lib.mkForce [];
    };
    Install.WantedBy = lib.mkForce ["default.target"];
  };

  programs.ai.enable = true;

  services.cloud-sync = {
    enable = true;
    syncInterval = "15m";

    googleDrive = {
      enable = true;
      remote = "gdrive";
      localPath = "${config.home.homeDirectory}/Cloud/GoogleDrive";
    };

    dropbox = {
      enable = true;
      remote = "dropbox";
      localPath = "${config.home.homeDirectory}/Cloud/Dropbox";
    };
  };
}
