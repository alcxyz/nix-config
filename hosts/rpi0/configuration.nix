# nix-config/hosts/rpi0/configuration.nix
{ config, pkgs, inputs, username, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    "${config.configDir}/modules/nixos/common/default.nix"
    "${config.configDir}/modules/nixos/common/server.nix"
  ];

  nixpkgs.config.allowUnfree = true;

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  services.journald.extraConfig = ''
    Storage=persistent
    SystemMaxUse=200M
  '';

  zramSwap.enable = true;

  sops = {
    defaultSopsFile = inputs.nix-secrets + "/secrets.yaml";
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };
}
