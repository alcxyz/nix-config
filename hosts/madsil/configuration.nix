# nix-config/hosts/madsil/configuration.nix
{
  pkgs,
  inputs,
  username,
  hostRole,
  configDir,
  lib,
  ...
}: let
  pkgsets = import "${configDir}/modules/shared/pkgsets.nix" {
    inherit pkgs inputs;
  };
in {
  imports = [
    ./hardware-configuration.nix
    "${configDir}/modules/nixos/common/default.nix"
    "${configDir}/modules/nixos/services/flatpak/default.nix"
    "${configDir}/modules/nixos/services/netbird/default.nix"
  ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

  environment.systemPackages = pkgsets.system.${hostRole.systemPackageSet};

  hardware.enableRedistributableFirmware = true;

  alc.shell = {
    default = "bash";
    enableNushell = false;
  };

  users.users.madsil = {
    isNormalUser = true;
    description = "Madsil";
    createHome = true;
    shell = pkgs.bashInteractive;
    initialPassword = "changeme";
    extraGroups = [
      "audio"
      "input"
      "networkmanager"
      "video"
    ];
  };

  services.displayManager.hiddenUsers = [
    username
    "family"
  ];
  services.displayManager = {
    autoLogin = {
      enable = true;
      user = "madsil";
    };
    gdm.enable = true;
  };
  services.desktopManager.gnome.enable = true;
  services.gnome.gnome-keyring.enable = true;
  programs.dconf = {
    enable = true;
    profiles.gdm.databases = [
      {
        settings."org/gnome/login-screen".disable-user-list = true;
      }
    ];
  };

  services.fwupd.enable = true;
  services.printing.enable = true;
  services.flatpak.managed = {
    enable = true;
    packages = [
      "com.heroicgameslauncher.hgl"
    ];
  };

  programs.steam.enable = true;
  programs.gamemode.enable = true;

  services.netbird.managed = {
    enable = true;
    disableDns = true;
  };

  networking.hosts = {
    "100.82.58.0" = ["madsil"];
  };

  nix.settings.max-jobs = 4;

  system.stateVersion = lib.mkForce "25.11";
}
