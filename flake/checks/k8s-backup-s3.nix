{
  inputs,
  pkgs,
}: let
  system = pkgs.stdenv.hostPlatform.system;
  lib = pkgs.lib;
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
      mirrorChecksumBuckets = ["fixture"];
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
  snapshotMirror = evaluate (mirrorPolicy // {mirrorSnapshotRetention = 2;});
  onDemandMirror = evaluate (mirrorPolicy // {alwaysOn = false;});
  incrementalMirror = evaluate (mirrorPolicy
    // {
      mirrorFullVerificationDay = "Sat";
      mirrorSnapshotRetention = 2;
    });
  splitPolicy =
    mirrorPolicy
    // {
      mirrorBandwidthLimit = "5M";
      mirrorExtraSources = [
        {
          name = "extra";
          endpoint = "http://192.0.2.12:9000";
          buckets = ["extra-bucket"];
          accessKeyFile = "/run/credentials/k8s-backup-extra-access";
          secretKeyFile = "/run/credentials/k8s-backup-extra-secret";
          bandwidthLimit = "10M";
        }
      ];
    };
  splitMirror = evaluate splitPolicy;
  splitBaseIncremental = evaluate (mirrorPolicy // {mirrorFullVerificationDay = "Sat";});
  splitIncremental = evaluate (splitPolicy // {mirrorFullVerificationDay = "Sat";});
  extraSource = builtins.head splitPolicy.mirrorExtraSources;
  disabled = evaluate {enable = false;};
  evaluateLocalBackup = localBackup:
    (zfs.extendModules {
      modules = [
        ../../hosts/xyz/storage.nix
        {
          disabledModules = [../../modules/nixos/hardware/zfs-latest-kernel.nix];
          options.services.forgejo-actions-runner = {
            isolatedDocker.enable = lib.mkEnableOption "fixture";
            cachePressure.mountPoint = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/fixture-cache";
            };
          };
          config.xyz.storage.policy = {
            runtime = {
              pool = "fixture-runtime";
              datasets = {
                docker = "fixture-runtime/docker";
                steam-headless = "fixture-runtime/steam";
              };
              retiredK3sDataset = "fixture-runtime/retired";
            };
            appState.datasets = lib.genAttrs ["calibre" "calibre-web" "plex" "qbittorrent" "stash"] (name: "fixture-appstate/${name}");
            localBackup =
              {
                pool = "fixture-backup";
                lockLabel = "fixture";
                appStateRoot = "fixture-backup/appstate";
                appStateSchedule = "daily";
              }
              // localBackup;
            games = {
              pool = "fixture-games";
              dataset = "fixture-games/data";
              mountpoint = "/var/lib/fixture-games";
            };
          };
        }
      ];
    }).config;
  legacyLocalBackup = evaluateLocalBackup {
    k8sDataset = "fixture/k8s-backups";
    k8sRoot = "fixture-backup/k8s";
    k8sSchedule = "daily";
  };
  directLocalBackup = evaluateLocalBackup {replicateK8s = false;};
  localReplicationValid = cfg:
    builtins.all (entry: entry.assertion) ((import ../../hosts/xyz/storage.nix {
      config = cfg;
      inherit lib pkgs;
    }).config.assertions);
  directLocalBackupPackage = builtins.head (builtins.filter (package: lib.getName package == "xyz-local-backup") directLocalBackup.environment.systemPackages);
in
  assert builtins.deepSeq [
    zfs.config.system.build.toplevel.drvPath
    mounted.config.system.build.toplevel.drvPath
    mirror.config.system.build.toplevel.drvPath
    snapshotMirror.config.system.build.toplevel.drvPath
    disabled.config.system.build.toplevel.drvPath
  ]
  true;
  assert legacyLocalBackup.xyz.storage.policy.localBackup.replicateK8s;
  assert localReplicationValid legacyLocalBackup;
  assert localReplicationValid directLocalBackup;
  assert !(localReplicationValid (evaluateLocalBackup {}));
  assert !(localReplicationValid (evaluateLocalBackup {
    k8sDataset = "fixture/same";
    k8sRoot = "fixture/same";
    k8sSchedule = "daily";
  }));
  assert !(localReplicationValid (evaluateLocalBackup {
    k8sDataset = "fixture/source";
    k8sRoot = "fixture/destination";
  }));
  assert legacyLocalBackup.systemd.timers.xyz-k8s-backup.timerConfig.OnCalendar == "daily";
  assert lib.hasSuffix " k8s" legacyLocalBackup.systemd.services.xyz-k8s-backup.serviceConfig.ExecStart;
  assert !(builtins.hasAttr "xyz-k8s-backup" directLocalBackup.systemd.services);
  assert !(builtins.hasAttr "xyz-k8s-backup" directLocalBackup.systemd.timers);
  assert builtins.deepSeq directLocalBackupPackage.drvPath true;
  assert mounted.config.services.k8s-backup-s3.dataset == null;
  assert mounted.config.services.k8s-backup-s3.quota == null;
  assert mounted.config.services.k8s-backup-s3.mirrorSchedule == null;
  assert mirror.config.services.k8s-backup-s3.mirrorSnapshotRetention == 0;
  assert mirror.config.systemd.services.k8s-backup-s3-mirror.serviceConfig.LoadCredential
  == [
    "s3_access_key:/run/credentials/k8s-backup-access"
    "s3_secret_key:/run/credentials/k8s-backup-secret"
  ];
  assert builtins.elem "source_extra_access_key:/run/credentials/k8s-backup-extra-access"
  splitMirror.config.systemd.services.k8s-backup-s3-mirror.serviceConfig.LoadCredential;
  assert fails (zfsPolicy // {mirrorExtraSources = splitPolicy.mirrorExtraSources;});
  assert fails (splitPolicy // {mirrorExtraSources = [extraSource extraSource];});
  assert fails (splitPolicy // {mirrorExtraSources = [(extraSource // {name = "source";})];});
  assert fails (splitPolicy // {mirrorExtraSources = [extraSource (extraSource // {name = "other";})];});
  assert fails (splitPolicy // {mirrorExtraSources = [(extraSource // {endpoint = "http://192.0.2.10:9000";})];});
  assert fails (splitPolicy // {mirrorExtraSources = [(extraSource // {buckets = [];})];});
  assert fails (splitPolicy // {mirrorBandwidthLimit = "fast";});
  # rclone reads a bare number as KiB/s.
  assert fails (splitPolicy // {mirrorBandwidthLimit = "1048576";});
  assert fails (splitPolicy // {mirrorExtraSources = [(extraSource // {bandwidthLimit = "10";})];});
  assert builtins.all (bucket: fails (splitPolicy // {mirrorExtraSources = [(extraSource // {buckets = [bucket];})];})) [
    ""
    "fixture/wal"
    "Fixture"
    "a"
    "-fixture"
    "fixture..wal"
    "192.0.2.10"
  ];
  assert !(fails (splitPolicy // {mirrorExtraSources = [(extraSource // {buckets = ["fixture.wal" "postgres-1.2"];})];}));
  assert !(builtins.elem mirror.config.boot.zfs.package mirror.config.systemd.services.k8s-backup-s3-mirror.path);
  assert builtins.elem snapshotMirror.config.boot.zfs.package snapshotMirror.config.systemd.services.k8s-backup-s3-mirror.path;
  assert builtins.elem pkgs.util-linux zfs.config.systemd.services.k8s-backup-s3-storage.path;
  assert !(builtins.hasAttr "k8s-backup-s3-mirror" mounted.config.systemd.services);
  assert mirror.config.systemd.timers."k8s-backup-s3-mirror".timerConfig.OnCalendar == "*-*-* 01:00:00";
  assert mirror.config.services.k8s-backup-s3.mirrorFullVerificationDay == null;
  assert fails (mirrorPolicy // {mirrorFullVerificationDay = "Saturday";});
  assert !mirror.config.systemd.services.k8s-backup-s3-mirror.restartIfChanged;
  assert !onDemandMirror.config.systemd.services.k8s-backup-rustfs.restartIfChanged;
  assert !onDemandMirror.config.systemd.services.k8s-backup-s3-storage.restartIfChanged;
  assert onDemandMirror.config.systemd.services.k8s-backup-s3-storage.unitConfig.StopWhenUnneeded;
  assert onDemandMirror.config.systemd.services.k8s-backup-s3-storage.requires == [];
  assert builtins.elem "zfs-mount.service" onDemandMirror.config.systemd.services.k8s-backup-s3-storage.wants;
  assert builtins.elem "zfs-mount.service" zfs.config.systemd.services.k8s-backup-s3-storage.requires;
  assert zfs.config.systemd.services.k8s-backup-rustfs.restartIfChanged;
  assert zfs.config.systemd.services.k8s-backup-s3-storage.restartIfChanged;
  assert mounted.config.systemd.services.k8s-backup-s3-storage.restartIfChanged;
  assert fails (common // {storageMode = "zfs";});
  assert fails (zfsPolicy // {dataset = null;});
  assert fails (zfsPolicy // {quota = null;});
  assert fails (zfsPolicy // {mirrorSnapshotRetention = 1;});
  assert fails (mirrorPolicy // {mirrorSnapshotRetention = -1;});
  assert fails (mirrorPolicy
    // {
      mirrorSnapshotRetention = 1;
      dataset = null;
    });
  assert fails (mirrorPolicy
    // {
      mirrorSnapshotRetention = 1;
      dataset = "";
    });
  assert fails (mountedPolicy
    // {
      mirrorSourceEndpoint = "http://192.0.2.11:9000";
      mirrorSchedule = "*-*-* 01:00:00";
      mirrorSnapshotRetention = 1;
    });
  assert fails (zfsPolicy // {mirrorSourceEndpoint = "http://192.0.2.11:9000";});
  assert builtins.all (name: fails (builtins.removeAttrs zfsPolicy [name])) [
    "storageMode"
    "dataDir"
    "apiAddress"
    "consoleAddress"
    "serviceUid"
    "serviceGid"
  ];
    pkgs.runCommand "k8s-backup-s3-interface-contract" {
      nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.jq pkgs.python3 pkgs.rclone];
    } ''
      timeout -k 5 180 python3 ${./test-k8s-backup-s3.py} \
        ${pkgs.writeText "k8s-backup-s3-mirror-fixture.sh" mirror.config.systemd.services.k8s-backup-s3-mirror.script} \
        ${pkgs.writeText "k8s-backup-s3-snapshot-fixture.sh" snapshotMirror.config.systemd.services.k8s-backup-s3-mirror.script} \
        ${pkgs.writeText "k8s-backup-s3-incremental-fixture.sh" incrementalMirror.config.systemd.services.k8s-backup-s3-mirror.script} \
        ${pkgs.writeText "k8s-backup-s3-storage-fixture.sh" zfs.config.systemd.services.k8s-backup-s3-storage.script} \
        ${pkgs.writeText "xyz-local-backup-disabled-fixture.sh" (builtins.unsafeDiscardStringContext directLocalBackupPackage.text)} \
        ${pkgs.writeText "k8s-backup-s3-split-fixture.sh" splitMirror.config.systemd.services.k8s-backup-s3-mirror.script} \
        ${pkgs.writeText "k8s-backup-s3-split-base-incremental-fixture.sh" splitBaseIncremental.config.systemd.services.k8s-backup-s3-mirror.script} \
        ${pkgs.writeText "k8s-backup-s3-split-incremental-fixture.sh" splitIncremental.config.systemd.services.k8s-backup-s3-mirror.script}
      touch "$out"
    ''
