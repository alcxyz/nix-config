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
  runtimeStoragePolicy = pkgs.writeShellScriptBin "xyz-runtime-storage-policy" ''
    set -euo pipefail

    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.util-linux
        zfsPackage
      ]
    }

    pool=${lib.escapeShellArg runtimePool}
    if [ "$(zpool list -H -o health "$pool" 2>/dev/null || true)" != ONLINE ]; then
      echo "runtime pool '$pool' is unavailable or unhealthy" >&2
      exit 1
    fi

    zpool set autotrim=off "$pool"

    for dataset in \
      ${lib.escapeShellArg runtimeDatasets.docker} \
      ${lib.escapeShellArg runtimeDatasets.steam-headless}; do
      if ! zfs list -H "$dataset" >/dev/null 2>&1; then
        echo "required runtime dataset '$dataset' is missing" >&2
        exit 1
      fi
      zfs set compression=zstd atime=off xattr=sa acltype=posixacl "$dataset"
    done

    zfs set quota=100G ${lib.escapeShellArg runtimeDatasets.docker}
    zfs set quota=40G refreservation=20G ${lib.escapeShellArg runtimeDatasets.steam-headless}

    retired_k3s_dataset=${lib.escapeShellArg retiredK3sRuntimeDataset}
    if zfs list -H "$retired_k3s_dataset" >/dev/null 2>&1; then
      zfs set canmount=noauto "$retired_k3s_dataset"
      if [ "$(zfs get -H -o value mounted "$retired_k3s_dataset")" = yes ]; then
        mounted_source="$(findmnt -rn -o SOURCE --target /var/lib/rancher/k3s 2>/dev/null || true)"
        if [ "$mounted_source" != "$retired_k3s_dataset" ]; then
          echo "/var/lib/rancher/k3s is mounted from '$mounted_source', expected '$retired_k3s_dataset'" >&2
          exit 1
        fi
        umount /var/lib/rancher/k3s
      fi
    fi

    check_mount() {
      local mountpoint="$1"
      local expected="$2"
      local source

      source="$(findmnt -rn -o SOURCE --target "$mountpoint" 2>/dev/null || true)"
      if [ "$source" != "$expected" ]; then
        echo "$mountpoint is mounted from '$source', expected '$expected'" >&2
        exit 1
      fi
    }

    check_mount /var/lib/docker ${lib.escapeShellArg runtimeDatasets.docker}
    check_mount /var/lib/steam-headless ${lib.escapeShellArg runtimeDatasets.steam-headless}
  '';
  localBackup = pkgs.writeShellScriptBin "xyz-local-backup" ''
    set -euo pipefail

    if [ "$(id -u)" -ne 0 ]; then
      echo "xyz-local-backup must run as root" >&2
      exit 1
    fi

    if [ "$#" -ne 1 ]; then
      echo "usage: xyz-local-backup {appstate|k8s}" >&2
      exit 64
    fi

    backup_name="$1"

    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.util-linux
        pkgs.sanoid
        zfsPackage
      ]
    }

    target_pool=${lib.escapeShellArg appStateBackupPool}

    if ! zpool list -H "$target_pool" >/dev/null 2>&1; then
      echo "backup pool '$target_pool' is not imported; create/import it before running local backups" >&2
      exit 1
    fi

    target_pool_encryption="$(zfs get -H -o value encryption "$target_pool" 2>/dev/null || echo off)"
    if [ "$target_pool_encryption" = off ]; then
      echo "backup pool '$target_pool' is not encrypted; refusing to write unencrypted local backups" >&2
      exit 1
    fi

    target_pool_keystatus="$(zfs get -H -o value keystatus "$target_pool" 2>/dev/null || echo unavailable)"
    if [ "$target_pool_keystatus" != available ]; then
      echo "backup pool '$target_pool' key is not loaded; run: zfs load-key $target_pool" >&2
      exit 1
    fi

    lock_dir=/run/lock
    mkdir -p "$lock_dir"
    exec 9>"$lock_dir/xyz-local-backup-${cfg.localBackup.lockLabel}.lock"
    echo "waiting for ${cfg.localBackup.lockLabel} backup lock for $backup_name"
    flock 9
    echo "acquired ${cfg.localBackup.lockLabel} backup lock for $backup_name"

    ensure_backup_dataset() {
      local target_dataset="$1"

      if ! zfs list -H "$target_dataset" >/dev/null 2>&1; then
        zfs create -p \
          -o mountpoint=none \
          -o canmount=off \
          -o compression=zstd \
          -o atime=off \
          "$target_dataset"
      fi

      target_dataset_encryption="$(zfs get -H -o value encryption "$target_dataset" 2>/dev/null || echo off)"
      if [ "$target_dataset_encryption" = off ]; then
        echo "backup dataset '$target_dataset' is not encrypted; refusing to write unencrypted local backups" >&2
        exit 1
      fi

      target_dataset_keystatus="$(zfs get -H -o value keystatus "$target_dataset" 2>/dev/null || echo unavailable)"
      if [ "$target_dataset_keystatus" != available ]; then
        echo "backup dataset '$target_dataset' key is not loaded; run: zfs load-key $target_dataset" >&2
        exit 1
      fi
    }

    replicate_dataset() {
      local source_dataset="$1"
      local target_dataset="$2"
      local mode="$3"

      if ! zfs list -H "$source_dataset" >/dev/null 2>&1; then
        echo "source dataset '$source_dataset' does not exist" >&2
        exit 1
      fi

      ensure_backup_dataset "$target_dataset"

      syncoid_args=(
        --recursive
        --compress=none
        --recvoptions="u o canmount=off o readonly=on"
      )
      if [ "$mode" = skip-parent ]; then
        syncoid_args+=(--skip-parent)
      fi

      if [ "$mode" = include-parent ]; then
        target_snapshot_count="$(zfs list -H -t snapshot -o name -r "$target_dataset" 2>/dev/null | wc -l)"
        target_referenced_bytes="$(zfs get -Hp -o value referenced "$target_dataset" 2>/dev/null || echo 0)"

        if [ "$target_snapshot_count" -eq 0 ]; then
          if [ "$target_referenced_bytes" -gt 1048576 ]; then
            echo "target dataset '$target_dataset' has no snapshots but references data; refusing initial seed" >&2
            exit 1
          fi

          syncoid_args+=(--force-delete)
        fi
      fi

      syncoid \
        "''${syncoid_args[@]}" \
        "$source_dataset" \
        "$target_dataset"
    }

    case "$backup_name" in
      appstate)
        ${appStateReplicationCommands}
        ;;
      k8s)
        replicate_dataset ${lib.escapeShellArg k8sBackupDataset} ${lib.escapeShellArg k8sBackupRoot} include-parent
        ;;
      *)
        echo "unknown backup target '$backup_name'; expected appstate or k8s" >&2
        exit 64
        ;;
    esac
  '';
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
  gamesDatasetPrepare = pkgs.writeShellScriptBin "xyz-games-dataset-prepare" ''
    set -euo pipefail

    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.util-linux
        zfsPackage
      ]
    }

    dataset=${lib.escapeShellArg gamesDataset}
    mountpoint=${lib.escapeShellArg gamesMountpoint}
    pool=${lib.escapeShellArg gamesPool}

    if ! zpool list -H "$pool" >/dev/null 2>&1; then
      echo "games pool '$pool' is not imported" >&2
      exit 1
    fi

    pool_encryption="$(zfs get -H -o value encryption "$pool" 2>/dev/null || echo off)"
    pool_keystatus="$(zfs get -H -o value keystatus "$pool" 2>/dev/null || echo unavailable)"
    if [ "$pool_encryption" != off ] && [ "$pool_keystatus" != available ]; then
      echo "games pool '$pool' key is not loaded; run: zfs load-key $pool" >&2
      exit 1
    fi

    install -d -m 0755 "$(dirname "$mountpoint")"

    if ! zfs list -H "$dataset" >/dev/null 2>&1; then
      zfs create -p \
        -o mountpoint="$mountpoint" \
        -o compression=lz4 \
        -o atime=off \
        "$dataset"
    else
      current_mountpoint="$(zfs get -H -o value mountpoint "$dataset")"
      if [ "$current_mountpoint" != "$mountpoint" ]; then
        zfs set mountpoint="$mountpoint" "$dataset"
      fi
      zfs set compression=lz4 "$dataset"
      zfs set atime=off "$dataset"
    fi

    current_source="$(findmnt -rn -o SOURCE --mountpoint "$mountpoint" 2>/dev/null || true)"
    if [ -n "$current_source" ] && [ "$current_source" != "$dataset" ]; then
      echo "$mountpoint is already mounted from '$current_source', expected '$dataset'" >&2
      exit 1
    fi

    if [ -z "$current_source" ]; then
      zfs mount "$dataset"
    fi
    [ "$(findmnt -rn -o SOURCE --mountpoint "$mountpoint")" = "$dataset" ] || {
      echo "$mountpoint is not mounted from '$dataset'" >&2
      exit 1
    }
    chown root:media "$mountpoint"
    chmod 0770 "$mountpoint"
  '';
in {
  imports = [./storage-policy-options.nix];

  config = {
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
    fileSystems."/var/lib/steam-headless" = {
      device = runtimeDatasets.steam-headless;
      fsType = "zfs";
      options = ["nofail"];
    };

    systemd.services.xyz-runtime-storage-policy = {
      description = "Enforce and verify xyz runtime storage policy";
      after = [
        "zfs-mount.service"
        "var-lib-docker.mount"
        "var-lib-steam\\x2dheadless.mount"
      ];
      requires = [
        "zfs-mount.service"
        "var-lib-docker.mount"
        "var-lib-steam\\x2dheadless.mount"
      ];
      before = [
        "docker.service"
        "xyz-appstate-backup.service"
      ];
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
