{
  config,
  pkgs,
  inputs,
  username,
  hostRole,
  configDir,
  lib,
  ...
}: let
  pkgsets = import "${configDir}/modules/nixos/common/pkgsets.nix" {
    inherit pkgs inputs;
  };
in {
  # ==================== Imports ====================
  #imports = [
  #];

  # ==================== Users ====================
  users.users.${username}.extraGroups = [
  ];

  # ==================== System Packages ====================
  environment.systemPackages = pkgsets.system.${hostRole.systemPackageSet};

  # ==================== Distributed Builds ====================
  systemd.tmpfiles.rules = [
    "d /root/.ssh 0700 root root - -"
  ];

  sops.secrets = {
    buildhost_xyz_private_key = {
      key = "ssh_buildhost_xyz";
      path = "/root/.ssh/id_buildhost_xyz";
      owner = "root";
      group = "root";
      mode = "0600";
    };
    buildhost_xyz_public_key = {
      key = "ssh_buildhost_xyz.pub";
      path = "/root/.ssh/id_buildhost_xyz.pub";
      owner = "root";
      group = "root";
      mode = "0644";
    };
  };

  nix = {
    distributedBuilds = true;
    buildMachines = [
      {
        hostName = "xyz";
        sshUser = "root";
        sshKey = "/root/.ssh/id_buildhost_xyz";
        systems = ["x86_64-linux" "aarch64-linux"];
        maxJobs = 8;
        speedFactor = 2;
        supportedFeatures = ["big-parallel" "kvm"];
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
