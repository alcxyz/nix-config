# nix-config/hosts/rpi0/configuration.nix
{ config, pkgs, inputs, username, lib, configDir, ... }:

{
  imports = [
    ./hardware-configuration.nix
    "${configDir}/modules/nixos/common/default.nix"
    "${configDir}/modules/nixos/common/server.nix"
  ];

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  nix.settings.require-sigs = false;

  services.journald.extraConfig = ''
    Storage=persistent
    SystemMaxUse=200M
  '';

  zramSwap.enable = true;

  sops.secrets = {
    #pihole_secret_key = {
    #  sopsFile = "${inputs.nix-secrets}/shared/secrets.yaml";
    #  owner = "root";
    #  group = "root";
    #};
  };

}
