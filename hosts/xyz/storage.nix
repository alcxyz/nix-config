# hosts/xyz/storage.nix
{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.xyz.storage.policy;
  zfsPackage = pkgs.openzfs_7_1;
  zfsKernelPackages = pkgs.linuxPackages_latest.extend (
    _final: kernelPackages: {
      openzfs_7_1 = zfsPackage.override {
        configFile = "kernel";
        kernel = kernelPackages.kernel;
      };
    }
  );
  runtimePool = cfg.runtime.pool;
  runtimeDatasets = cfg.runtime.datasets;
  isolatedDockerEnabled = config.services.forgejo-actions-runner.isolatedDocker.enable;
  forgejoDockerConfigured =
    runtimeDatasets.forgejo-docker != null && cfg.runtime.forgejoDockerQuota != null;
  forgejoDockerStorageEnabled = isolatedDockerEnabled && forgejoDockerConfigured;
  forgejoDockerDataset =
    if forgejoDockerStorageEnabled
    then runtimeDatasets.forgejo-docker
    else "";
  forgejoDockerQuota =
    if forgejoDockerStorageEnabled
    then cfg.runtime.forgejoDockerQuota
    else "";
  forgejoDockerMountUnit = "var-lib-forgejo\\x2ddocker.mount";
  retiredK3sRuntimeDataset = cfg.runtime.retiredK3sDataset;
  appStateDatasets = cfg.appState.datasets;
  appStateBackupPool = cfg.localBackup.pool;
  appStateBackupRoot = cfg.localBackup.appStateRoot;
  appStateReplicationCommands = lib.concatMapStringsSep "\n" (name: ''
    replicate_dataset \
      ${lib.escapeShellArg appStateDatasets.${name}} \
      ${lib.escapeShellArg "${appStateBackupRoot}/${name}"} \
      include-parent
  '') (builtins.attrNames appStateDatasets);
  k8sBackupDataset = cfg.localBackup.k8sDataset;
  k8sBackupRoot = cfg.localBackup.k8sRoot;
  gamesPool = cfg.games.pool;
  gamesDataset = cfg.games.dataset;
  gamesMountpoint = cfg.games.mountpoint;
  runtimeStoragePolicy = pkgs.writeShellScriptBin "xyz-runtime-storage-policy" (
    lib.replaceStrings
    [
      "@path@"
      "@runtime_pool@"
      "@docker_dataset@"
      "@steam_headless_dataset@"
      "@forgejo_docker_dataset@"
      "@forgejo_docker_quota@"
      "@retired_k3s_dataset@"
    ]
    [
      (lib.makeBinPath [pkgs.coreutils pkgs.util-linux zfsPackage])
      (lib.escapeShellArg runtimePool)
      (lib.escapeShellArg runtimeDatasets.docker)
      (lib.escapeShellArg runtimeDatasets.steam-headless)
      (lib.escapeShellArg forgejoDockerDataset)
      (lib.escapeShellArg forgejoDockerQuota)
      (lib.escapeShellArg retiredK3sRuntimeDataset)
    ]
    (builtins.unsafeDiscardStringContext (builtins.readFile ./xyz-runtime-storage-policy.sh))
  );
  localBackup = pkgs.writeShellScriptBin "xyz-local-backup" (
    lib.replaceStrings
    [
      "@path@"
      "@backup_pool@"
      "@lock_label@"
      "@app_state_replication_commands@"
      "@k8s_backup_dataset@"
      "@k8s_backup_root@"
    ]
    [
      (lib.makeBinPath [pkgs.coreutils pkgs.util-linux pkgs.sanoid zfsPackage])
      (lib.escapeShellArg appStateBackupPool)
      cfg.localBackup.lockLabel
      appStateReplicationCommands
      (lib.escapeShellArg k8sBackupDataset)
      (lib.escapeShellArg k8sBackupRoot)
    ]
    (builtins.unsafeDiscardStringContext (builtins.readFile ./xyz-local-backup.sh))
  );
  mkLocalBackupService = backupName: description: {
    inherit description;
    after = ["zfs-mount.service"];
    requires = ["zfs-mount.service"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${localBackup}/bin/xyz-local-backup ${backupName}";
      TimeoutStartSec = "12h";
      Slice = "xyz-backups.slice";
      Nice = 15;
      IOSchedulingClass = "idle";
      CPUSchedulingPolicy = "idle";
    };
  };
  mkLocalBackupTimer = onCalendar: description: {
    inherit description;
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = onCalendar;
      Persistent = false;
      RandomizedDelaySec = "0";
    };
  };
  gamesDatasetPrepare = pkgs.writeShellScriptBin "xyz-games-dataset-prepare" (
    lib.replaceStrings
    [
      "@path@"
      "@games_dataset@"
      "@games_mountpoint@"
      "@games_pool@"
    ]
    [
      (lib.makeBinPath [pkgs.coreutils pkgs.util-linux zfsPackage])
      (lib.escapeShellArg gamesDataset)
      (lib.escapeShellArg gamesMountpoint)
      (lib.escapeShellArg gamesPool)
    ]
    (builtins.unsafeDiscardStringContext (builtins.readFile ./xyz-games-dataset-prepare.sh))
  );
in {
  imports = [./storage-policy-options.nix];

  config = {
    assertions = [
      {
        assertion =
          !isolatedDockerEnabled
          || forgejoDockerConfigured;
        message = "Isolated runner Docker on xyz requires a dedicated runtime dataset and quota.";
      }
    ];

    # See docs/adr/0035-host-kernel-policy.md: the matching OpenZFS module has
    # been compiled against this kernel before any separate activation step.
    boot.kernelPackages = zfsKernelPackages;
    boot.zfs.package = zfsPackage;

    # ==================== ZFS ====================
    environment.systemPackages = [
      localBackup
      gamesDatasetPrepare
      runtimeStoragePolicy
      zfsPackage
      pkgs.acl
      pkgs.gptfdisk
      pkgs.mergerfs
      pkgs.mergerfs-tools
      pkgs.parted
      pkgs.rsync
      pkgs.smartmontools
      pkgs.xfsprogs
    ];
    boot.supportedFilesystems = ["zfs"];
    boot.zfs.devNodes = "/dev/disk/by-id";
    boot.zfs.extraPools = [runtimePool];
    boot.zfs.forceImportRoot = false;
    # Keep swap as an OOM safety net, but prefer retaining latency-sensitive
    # desktop and game memory over filesystem cache during routine pressure.
    boot.kernel.sysctl."vm.swappiness" = 10;

    fileSystems."/var/lib/calibre" = {
      device = appStateDatasets.calibre;
      fsType = "zfs";
      options = ["nofail"];
    };
    fileSystems."/var/lib/calibre-web" = {
      device = appStateDatasets.calibre-web;
      fsType = "zfs";
      options = ["nofail"];
    };
    fileSystems."/var/lib/plex" = {
      device = appStateDatasets.plex;
      fsType = "zfs";
      options = ["nofail"];
    };
    fileSystems."/var/lib/qbittorrent" = {
      device = appStateDatasets.qbittorrent;
      fsType = "zfs";
      options = ["nofail"];
    };
    fileSystems."/var/lib/stash" = {
      device = appStateDatasets.stash;
      fsType = "zfs";
      options = ["nofail"];
    };
    fileSystems."/var/lib/docker" = {
      device = runtimeDatasets.docker;
      fsType = "zfs";
      options = ["nofail"];
    };
    fileSystems."/var/lib/forgejo-docker" = lib.mkIf forgejoDockerStorageEnabled {
      device = forgejoDockerDataset;
      fsType = "zfs";
      options = ["nofail"];
    };
    fileSystems."/var/lib/steam-headless" = {
      device = runtimeDatasets.steam-headless;
      fsType = "zfs";
      options = ["nofail"];
    };

    systemd.services.xyz-runtime-storage-policy = {
      description = "Enforce and verify xyz runtime storage policy";
      after =
        [
          "zfs-mount.service"
          "var-lib-docker.mount"
          "var-lib-steam\\x2dheadless.mount"
        ]
        ++ lib.optional forgejoDockerStorageEnabled forgejoDockerMountUnit;
      requires =
        [
          "zfs-mount.service"
          "var-lib-docker.mount"
          "var-lib-steam\\x2dheadless.mount"
        ]
        ++ lib.optional forgejoDockerStorageEnabled forgejoDockerMountUnit;
      before =
        [
          "docker.service"
          "xyz-appstate-backup.service"
        ]
        ++ lib.optional forgejoDockerStorageEnabled "forgejo-runner-docker.service";
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${runtimeStoragePolicy}/bin/xyz-runtime-storage-policy";
      };
    };

    systemd.services.xyz-appstate-backup =
      lib.recursiveUpdate
      (mkLocalBackupService "appstate" "Replicate xyz appstate datasets to the local backup pool")
      {
        after = ["xyz-runtime-storage-policy.service"];
        requires = ["xyz-runtime-storage-policy.service"];
      };
    systemd.services.xyz-k8s-backup =
      lib.recursiveUpdate
      (mkLocalBackupService "k8s" "Replicate xyz k8s backup dataset to the local backup pool")
      {
        # If the mirror is still activating, snapshot only after its verified
        # checkpoint has finished instead of capturing mid-copy state.
        after = [
          "zfs-mount.service"
          "k8s-backup-s3-mirror.service"
        ];
      };

    systemd.services.xyz-games-dataset = {
      description = "Prepare xyz games dataset";
      after = ["zfs-mount.service"];
      requires = ["zfs-mount.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${gamesDatasetPrepare}/bin/xyz-games-dataset-prepare";
      };
    };

    systemd.timers.xyz-appstate-backup = mkLocalBackupTimer cfg.localBackup.appStateSchedule "Daily xyz appstate backup";
    systemd.timers.xyz-k8s-backup = mkLocalBackupTimer cfg.localBackup.k8sSchedule "Daily xyz k8s backup replication";

    systemd.slices.xyz-backups = {
      description = "Contention-aware xyz backup workloads";
      sliceConfig = {
        CPUWeight = 10;
        IOWeight = 10;
      };
    };

    systemd.services.k8s-backup-rustfs.serviceConfig = {
      Slice = "xyz-backups.slice";
      Nice = 15;
      IOSchedulingClass = "idle";
      CPUSchedulingPolicy = "idle";
    };
    systemd.services.k8s-backup-s3-mirror.serviceConfig.Slice = "xyz-backups.slice";
    systemd.services.xyz-home-backup.serviceConfig.Slice = "xyz-backups.slice";
    systemd.services.snapshot-restic-home-maintenance.serviceConfig.Slice = "xyz-backups.slice";
    systemd.services.snapshot-restic-home-full-check.serviceConfig.Slice = "xyz-backups.slice";

    # Docker - ZFS relationship

    systemd.services.docker = {
      after = [
        "zfs-mount.service"
        "zfs-import.target"
        "zfs-auto-unlock.service"
        "xyz-runtime-storage-policy.service"
      ];

      requires = [
        "zfs-mount.service"
        "zfs-auto-unlock.service"
        "xyz-runtime-storage-policy.service"
      ];
    };

    systemd.services.forgejo-runner-docker = lib.mkIf forgejoDockerStorageEnabled {
      after = [
        "zfs-mount.service"
        "zfs-import.target"
        "zfs-auto-unlock.service"
        "xyz-runtime-storage-policy.service"
      ];
      requires = [
        "zfs-mount.service"
        "zfs-auto-unlock.service"
        "xyz-runtime-storage-policy.service"
      ];
    };
    services.forgejo-actions-runner.cachePressure.mountPoint =
      lib.mkIf forgejoDockerStorageEnabled "/var/lib/forgejo-docker";

    systemd.services.calibre-web = {
      requires = [
        "var-lib-calibre.mount"
        "var-lib-calibre\\x2dweb.mount"
      ];
      after = [
        "var-lib-calibre.mount"
        "var-lib-calibre\\x2dweb.mount"
      ];
    };
    systemd.services.plex = {
      requires = ["var-lib-plex.mount"];
      after = ["var-lib-plex.mount"];
    };
    systemd.services.qbittorrent = {
      requires = ["var-lib-qbittorrent.mount"];
      after = ["var-lib-qbittorrent.mount"];
    };
    systemd.services.stash = {
      requires = ["var-lib-stash.mount"];
      after = ["var-lib-stash.mount"];
    };
  };
}
