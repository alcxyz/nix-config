{
  inputs,
  lib,
  pkgs,
}: let
  system = inputs.nixpkgs.lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      ../../modules/nixos/common/nsswitch.nix
      {
        services.avahi = {
          enable = true;
          nssmdns4 = true;
        };
        system.nssDatabases.hosts = lib.mkOrder 700 [
          "custom-resolver"
          "files"
          "custom-resolver"
        ];
      }
    ];
  };
  hosts = system.config.system.nssDatabases.hosts;
in
  assert hosts
  == [
    "files"
    "mymachines"
    "mdns4_minimal [NOTFOUND=return]"
    "custom-resolver"
    "custom-resolver"
    "myhostname"
    "dns"
  ];
    pkgs.runCommand "nsswitch-hosts-contract" {} ''
      touch "$out"
    ''
