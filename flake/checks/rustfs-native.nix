{
  inputs,
  pkgs,
}:
let
  lib = pkgs.lib;
  package = pkgs.writeShellScriptBin "rustfs" "exit 0";
  base = {
    enable = true;
    inherit package;
    endpoints = [
      "http://node-a.example.invalid:9000/var/lib/rustfs-app"
      "http://node-b.example.invalid:9000/var/lib/rustfs-app"
      "http://node-c.example.invalid:9000/var/lib/rustfs-app"
    ];
    localEndpointHost = "node-a.example.invalid";
    dataDir = "/var/lib/rustfs-app";
    mountPoint = "/var/lib";
    accessKeyFile = "/run/credentials/rustfs-access";
    secretKeyFile = "/run/credentials/rustfs-secret";
  };
  evaluate =
    policy:
    inputs.nixpkgs.lib.nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        ../../modules/nixos/services/rustfs-native/default.nix
        {
          boot.loader.grub.devices = [ "nodev" ];
          fileSystems."/" = {
            device = "/dev/disk/by-label/fixture";
            fsType = "ext4";
          };
          services.rustfs-native = policy;
          system.stateVersion = "26.11";
        }
      ];
    };
  cfg = (evaluate base).config;
  service = cfg.systemd.services.rustfs-native;
  invalid =
    policy:
    !(builtins.tryEval (builtins.deepSeq (evaluate policy).config.system.build.toplevel.drvPath true))
    .success;
in
assert builtins.deepSeq cfg.system.build.toplevel.drvPath true;
assert service.serviceConfig.User == "rustfs-app";
assert service.serviceConfig.Group == "rustfs-app";
assert
  service.serviceConfig.LoadCredential == [
    "rustfs_access_key:/run/credentials/rustfs-access"
    "rustfs_secret_key:/run/credentials/rustfs-secret"
  ];
assert lib.hasInfix "--access-key-file=%d/rustfs_access_key" service.serviceConfig.ExecStart;
assert !(lib.hasInfix "--console-enable" service.serviceConfig.ExecStart);
assert lib.elem "RUSTFS_CONSOLE_ENABLE=false" service.serviceConfig.Environment;
assert lib.elem "/var/lib/rustfs-app" service.unitConfig.RequiresMountsFor;
assert lib.hasInfix "mountpoint -q" (builtins.head service.serviceConfig.ExecStartPre);
assert lib.hasInfix "install -d" (builtins.elemAt service.serviceConfig.ExecStartPre 1);
assert lib.elem "RUSTFS_LOCAL_ENDPOINT_HOST=node-a.example.invalid"
  service.serviceConfig.Environment;
assert service.serviceConfig.ReadWritePaths == [ "-/var/lib/rustfs-app" ];
assert service.serviceConfig.MemoryHigh == "2G";
assert invalid (base // { dataDir = "relative"; });
assert invalid (base // { localEndpointHost = "missing.example.invalid"; });
assert invalid (base // { endpoints = [ ]; });
assert invalid (base // { mountPoint = "/srv/unrelated"; });
pkgs.runCommand "rustfs-native-interface-contract" { } ''
  touch "$out"
''
