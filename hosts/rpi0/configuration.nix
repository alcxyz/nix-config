# hosts/rpi0/configuration.nix
{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  nixpkgs.config.allowUnfree = true;

  networking.hostName = "rpi0";
  time.timeZone = "Europe/Oslo";

  # Network
  networking.useDHCP = lib.mkDefault true;
  networking.networkmanager.enable = true;

  # SSH & user
  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = false;

  users.users.alc = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = [
	"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM9g7HJbiqvmCZRZF5z5g9J/VLI91p7RpXipA9eWHX2q alc@xyz"
    ];
  };

  hardware.enableRedistributableFirmware = true;

  # Bootloader: U-Boot + extlinux
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Journald limits for eMMC
  services.journald.extraConfig = ''
    Storage=persistent
    SystemMaxUse=200M
  '';

  zramSwap.enable = true;
}
