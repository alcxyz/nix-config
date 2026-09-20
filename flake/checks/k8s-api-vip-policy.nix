{
  inputs,
  pkgs,
}: let
  policy = {
    enable = true;
    interface = "eth0";
    sourceIp = "192.0.2.10";
    peers = ["192.0.2.11"];
    vip = "192.0.2.20";
    prefixLength = 24;
    virtualRouterId = 42;
  };
  evaluate = settings:
    inputs.nixpkgs.lib.nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        ../../modules/nixos/services/k8s-api-vip/default.nix
        {
          boot.loader.grub.devices = ["nodev"];
          fileSystems."/" = {
            device = "/dev/disk/by-label/fixture";
            fsType = "ext4";
          };
          services.k8s-api-vip = settings;
          system.stateVersion = "26.11";
        }
      ];
    };
  force = settings: (evaluate settings).config.system.build.toplevel.drvPath;
  fails = settings: !(builtins.tryEval (builtins.deepSeq (force settings) true)).success;
in
  assert builtins.deepSeq [(force policy) (force {enable = false;})] true;
  assert builtins.all (name: fails (builtins.removeAttrs policy [name])) [
    "vip"
    "prefixLength"
    "virtualRouterId"
  ];
    pkgs.runCommand "k8s-api-vip-policy-contract" {} ''
      touch "$out"
    ''
