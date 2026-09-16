{
  inputs,
  pkgs,
}: let
  system = pkgs.stdenv.hostPlatform.system;
  common = {
    enable = true;
    dataDir = "/var/lib/k8s-backup-fixture";
    apiAddress = "192.0.2.10:9000";
    consoleAddress = "127.0.0.1:9001";
    accessKeyFile = "/run/credentials/k8s-backup-access";
    secretKeyFile = "/run/credentials/k8s-backup-secret";
    serviceUid = 45001;
    serviceGid = 45001;
    openFirewall = false;
  };
  zfsPolicy =
    common
    // {
      storageMode = "zfs";
      dataset = "fixture/k8s-backups";
      quota = "1G";
    };
  mountedPolicy =
    common
    // {
      storageMode = "mounted-filesystem";
      storageUnit = "var-lib-k8s-backup-fixture.mount";
    };
  mirrorPolicy =
    zfsPolicy
    // {
      mirrorSourceEndpoint = "http://192.0.2.11:9000";
      mirrorSchedule = "*-*-* 01:00:00";
    };
  evaluate = policy:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {inherit inputs;};
      modules = [
        ../../modules/nixos/services/k8s-backup-s3/default.nix
        {
          boot.loader.grub.devices = ["nodev"];
          fileSystems."/" = {
            device = "/dev/disk/by-label/fixture";
            fsType = "ext4";
          };
          services.k8s-backup-s3 = policy;
          system.stateVersion = "26.11";
        }
      ];
    };
  force = policy: (evaluate policy).config.system.build.toplevel.drvPath;
  fails = policy: !(builtins.tryEval (builtins.deepSeq (force policy) true)).success;
  zfs = evaluate zfsPolicy;
  mounted = evaluate mountedPolicy;
  mirror = evaluate mirrorPolicy;
  disabled = evaluate {enable = false;};
in
  assert builtins.deepSeq [
    zfs.config.system.build.toplevel.drvPath
    mounted.config.system.build.toplevel.drvPath
    mirror.config.system.build.toplevel.drvPath
    disabled.config.system.build.toplevel.drvPath
  ]
  true;
  assert mounted.config.services.k8s-backup-s3.dataset == null;
  assert mounted.config.services.k8s-backup-s3.quota == null;
  assert mounted.config.services.k8s-backup-s3.mirrorSchedule == null;
  assert !(builtins.hasAttr "k8s-backup-s3-mirror" mounted.config.systemd.services);
  assert mirror.config.systemd.timers."k8s-backup-s3-mirror".timerConfig.OnCalendar == "*-*-* 01:00:00";
  assert fails (common // {storageMode = "zfs";});
  assert fails (zfsPolicy // {dataset = null;});
  assert fails (zfsPolicy // {quota = null;});
  assert fails (zfsPolicy // {mirrorSourceEndpoint = "http://192.0.2.11:9000";});
  assert builtins.all (name: fails (builtins.removeAttrs zfsPolicy [name])) [
    "storageMode"
    "dataDir"
    "apiAddress"
    "consoleAddress"
    "serviceUid"
    "serviceGid"
  ];
    pkgs.runCommand "k8s-backup-s3-interface-contract" {} ''
      touch "$out"
    ''
