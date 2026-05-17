# nix-config/hosts/family-thinkpad/configuration.nix
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
    "${configDir}/modules/nixos/services/netbird/default.nix"
  ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

  environment.systemPackages = pkgsets.system.${hostRole.systemPackageSet};

  hardware.enableRedistributableFirmware = true;

  users.users.family = {
    isNormalUser = true;
    description = "Family";
    createHome = true;
    initialPassword = "changeme";
    extraGroups = [
      "audio"
      "input"
      "networkmanager"
      "video"
    ];
  };

  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;
  services.gnome.gnome-keyring.enable = true;

  services.fwupd.enable = true;
  services.printing.enable = true;
  services.flatpak.enable = true;

  programs.steam.enable = true;
  programs.gamemode.enable = true;

  services.netbird.managed = {
    enable = true;
    disableDns = true;
  };

  networking.hosts = {
    "192.168.1.14" = ["family-thinkpad"];
  };

  nix.settings.max-jobs = 4;

  system.stateVersion = lib.mkForce "25.11";
}
