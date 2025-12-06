{ config, pkgs, inputs, username, configDir, lib, ... }:

let
  pkgsets = import ../pkgsets.nix { inherit pkgs inputs; };
in

{
  # ==================== Imports ====================
  #imports = [
  #];

  # ==================== Users ====================
  users.users.${username}.extraGroups = [
    "networkmanager"
    "wheel"
  ];

  # ==================== System Packages ====================
  environment.systemPackages = pkgsets.system.server;

  # ==================== Distributed Builds ====================
  nix = {
    distributedBuilds = true;
    buildMachines = [
      {
        hostName = "xyz";
        sshUser = username;
        system = "x86_64-linux";
        maxJobs = 8;
        speedFactor = 2;
        supportedFeatures = [ "big-parallel" "kvm" ];
        protocol = "ssh-ng";
      }
    ];
    settings."builders-use-substitutes" = true;
  };

  # ==================== Services ====================
  services.xserver.enable = false;

  virtualisation.docker.enableNvidia = false;

  # ==================== Networking ====================
  networking.resolvconf.enable = true;
}
