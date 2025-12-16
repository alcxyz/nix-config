{ config, pkgs, inputs, username, configDir, lib, ... }:

let
  pkgsets = import "${configDir}/modules/nixos/common/pkgsets.nix" {
    inherit pkgs inputs;
  };
in

{
  # ==================== Imports ====================
  #imports = [
  #];

  # ==================== Users ====================
  users.users.${username}.extraGroups = [
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
        protocol = "ssh";
      }
    ];
    settings."builders-use-substitutes" = true;
  };

  # ==================== Services ====================
  services.xserver.enable = false;

  # ==================== Networking ====================
  networking.resolvconf.enable = true;
}
