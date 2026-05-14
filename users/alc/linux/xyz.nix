# users/alc/linux/xyz.nix
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
  # Import the common Linux configuration
  imports = [
    "${configDir}/users/alc/linux/operator.nix"

    "${configDir}/modules/home-manager/programs/wayland-common/default.nix"
    "${configDir}/modules/home-manager/programs/hyprland/default.nix"
    "${configDir}/modules/home-manager/programs/niri/default.nix"
    "${configDir}/modules/home-manager/services/dms/default.nix"
    "${configDir}/modules/home-manager/services/hyprlock/default.nix"
    "${configDir}/modules/home-manager/programs/foot/default.nix"

    "${configDir}/modules/home-manager/programs/rclone/cloud-sync.nix"

    "${configDir}/modules/home-manager/programs/ai/default.nix"

    "${configDir}/modules/home-manager/services/paperflow/default.nix"
    "${configDir}/modules/home-manager/services/paperless-filetype-index/default.nix"
    "${configDir}/modules/home-manager/services/devlog/default.nix"
    "${configDir}/modules/home-manager/services/t3code/default.nix"

    inputs.hyprscratch.homeModules.default
  ];

  # ==================== XYZ-Specific Settings ====================

  home.packages =
    pkgsets.home.${hostRole.homePackageSet}
    ++ [
      pkgs.paperweight
    ];

  programs.kubernetes.managed.wrap.leantimeTidy = true;

  # Symlink configs directly to repo checkout for live editing
  xdg.configFile."ncspot/config.toml".source =
    config.lib.file.mkOutOfStoreSymlink "${configDir}/users/alc/configs/ncspot/config.toml";

  # XYZ-specific aliases
  home.shellAliases = {
    pbcopy = "wl-copy";
    pbpaste = "wl-paste";
    # Single-layer remote rebuilds (deploy <host> does both)
    nxsw-nux = "deploy --nixos nux";
    nxsw-nex = "deploy --nixos nex";
    nxsw-rpi0 = "deploy --nixos rpi0";
    hmsw-nux = "deploy --hm nux";
    hmsw-nex = "deploy --hm nex";
    hmsw-rpi0 = "deploy --hm rpi0";
  };

  # Enable XYZ-specific programs
  programs.foot.enable = true;
  programs.hyprland.managed.enable = true;
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

  services.dms.enable = true;
  services.hyprlock.enable = true;

  services.devlog.enable = true;
  services.devlog.weekly.enable = true;

  services.t3code.enable = false;
  services.t3code.port = 3777;

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

    nextcloud = {
      enable = true;
      remote = "nextcloud";
      localPath = "${config.home.homeDirectory}/Cloud/Nextcloud";
    };
  };
}
