{
  inputs,
  pkgs,
}: let
  system = pkgs.stdenv.hostPlatform.system;
  webUiTrustedClients = [
    "192.0.2.10"
    "198.51.100.0/24"
  ];
  evaluate = policy:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs.username = "fixture";
      modules = [
        ../../modules/nixos/services/torrent/default.nix
        {
          boot.loader.grub.devices = ["nodev"];
          fileSystems."/" = {
            device = "/dev/disk/by-label/fixture";
            fsType = "ext4";
          };
          users.groups.fixture = {};
          users.users.fixture = {
            isNormalUser = true;
            group = "fixture";
          };
          services.torrent = policy;
          system.stateVersion = "26.11";
        }
      ];
    };
  enabled = evaluate {
    enable = true;
    inherit webUiTrustedClients;
    zfsDatasets = [];
    storageDependencyUnits = [];
  };
  disabled = evaluate {enable = false;};
  force = policy: let
    evaluated = evaluate policy;
  in
    builtins.deepSeq [
      evaluated.config.services.torrent.webUiTrustedClients
      evaluated.config.networking.firewall.extraCommands
      evaluated.config.systemd.services.qbittorrent.preStart
      evaluated.config.system.build.toplevel.drvPath
    ]
    true;
  fails = policy: !(builtins.tryEval (force policy)).success;
  option = enabled.options.services.torrent.webUiTrustedClients;
  firewallRules = enabled.config.networking.firewall.extraCommands;
  qbittorrentPreStart = enabled.config.systemd.services.qbittorrent.preStart;
in
  assert builtins.deepSeq [
    enabled.config.system.build.toplevel.drvPath
    disabled.config.system.build.toplevel.drvPath
  ]
  true;
  assert !(builtins.hasAttr "default" option);
  assert option.type.check webUiTrustedClients;
  assert !option.type.check [];
  assert !option.type.check "192.0.2.10";
  assert enabled.config.services.torrent.webUiTrustedClients == webUiTrustedClients;
  assert builtins.all (client: inputs.nixpkgs.lib.hasInfix client firewallRules) webUiTrustedClients;
  assert inputs.nixpkgs.lib.hasInfix (inputs.nixpkgs.lib.concatStringsSep "," webUiTrustedClients) qbittorrentPreStart;
  assert fails {
    enable = true;
    zfsDatasets = [];
    storageDependencyUnits = [];
  };
  assert fails {
    enable = true;
    webUiTrustedClients = [];
    zfsDatasets = [];
    storageDependencyUnits = [];
  };
    pkgs.runCommand "torrent-policy-interface-contract" {} ''
      touch "$out"
    ''
