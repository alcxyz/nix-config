# nix-config/modules/nixos/services/snapshot-restic-home/default.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.snapshot-restic-home;
  zfsPackage = config.boot.zfs.package;
  repositoryPath = "${cfg.repositoryMountPoint}/repository";
  backupPath = "/run/snapshot-restic-home/source";
  excludeFile = pkgs.writeText "snapshot-restic-home-excludes" (
    lib.concatMapStringsSep "\n" (pattern: "${backupPath}${pattern}") cfg.excludePatterns + "\n"
  );
  resticEnvironment = ''
    export RESTIC_REPOSITORY=${lib.escapeShellArg repositoryPath}
    export RESTIC_PASSWORD_FILE=${lib.escapeShellArg cfg.passwordFile}
    export RESTIC_CACHE_DIR=/var/cache/snapshot-restic-home
  '';
  repositoryGuard = ''
    source="$(findmnt -rn -o SOURCE --target ${lib.escapeShellArg cfg.repositoryMountPoint} 2>/dev/null || true)"
    target="$(findmnt -rn -o TARGET --target ${lib.escapeShellArg cfg.repositoryMountPoint} 2>/dev/null || true)"
    if [ "$source" != ${lib.escapeShellArg cfg.repositoryDataset} ] || [ "$target" != ${lib.escapeShellArg cfg.repositoryMountPoint} ]; then
      echo "backup repository mount does not match its configured ZFS dataset" >&2
      exit 1
    fi
  '';
  prepareScript = pkgs.writeShellApplication {
    name = "snapshot-restic-home-prepare";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.restic
      pkgs.util-linux
      zfsPackage
    ];
    text = ''
      pool=${lib.escapeShellArg (builtins.head (lib.splitString "/" cfg.repositoryDataset))}
      dataset=${lib.escapeShellArg cfg.repositoryDataset}
      mountpoint=${lib.escapeShellArg cfg.repositoryMountPoint}

      if [ "$(zpool list -H -o health "$pool" 2>/dev/null || true)" != ONLINE ]; then
        echo "backup pool is unavailable or unhealthy" >&2
        exit 1
      fi

      if [ "$(zfs get -H -o value encryption "$pool" 2>/dev/null || echo off)" = off ]; then
        echo "backup pool is not encrypted" >&2
        exit 1
      fi
      if [ "$(zfs get -H -o value keystatus "$pool" 2>/dev/null || echo unavailable)" != available ]; then
        echo "backup pool key is unavailable" >&2
        exit 1
      fi

      if ! zfs list -H "$dataset" >/dev/null 2>&1; then
        zfs create -p \
          -o mountpoint="$mountpoint" \
          -o compression=zstd \
          -o atime=off \
          -o quota=${lib.escapeShellArg cfg.repositoryQuota} \
          "$dataset"
      else
        zfs set \
          mountpoint="$mountpoint" \
          compression=zstd \
          atime=off \
          quota=${lib.escapeShellArg cfg.repositoryQuota} \
          "$dataset"
      fi

      if ! findmnt -rn --target "$mountpoint" >/dev/null 2>&1; then
        zfs mount "$dataset"
      fi
      ${repositoryGuard}

      ${resticEnvironment}
      install -d -m 0700 "$mountpoint" "$RESTIC_REPOSITORY" "$RESTIC_CACHE_DIR"

      if [ -e "$RESTIC_REPOSITORY/config" ]; then
        restic cat config >/dev/null
      else
        if find "$RESTIC_REPOSITORY" -mindepth 1 -print -quit | grep -q .; then
          echo "refusing to initialize a non-empty backup repository" >&2
          exit 1
        fi
        restic init
      fi
    '';
  };
  backupScript = pkgs.writeShellApplication {
    name = "snapshot-restic-home-backup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.restic
      pkgs.util-linux
      zfsPackage
    ];
    text = ''
      ${resticEnvironment}
      ${repositoryGuard}

      install -d -m 0700 /run/snapshot-restic-home "$RESTIC_CACHE_DIR"
      exec 9>/run/lock/snapshot-restic-home.lock
      flock 9

      snapshot_name="restic-$(date -u +%Y%m%dT%H%M%SZ)-$$"
      snapshot=${lib.escapeShellArg cfg.sourceDataset}@"$snapshot_name"
      snapshot_path=${lib.escapeShellArg cfg.sourceMountPoint}/.zfs/snapshot/"$snapshot_name"/${lib.escapeShellArg cfg.sourceRelativePath}
      bind_path=${lib.escapeShellArg backupPath}
      snapshot_created=false
      bind_mounted=false

      cleanup() {
        status=$?
        trap - EXIT INT TERM
        if [ "$bind_mounted" = true ]; then
          umount "$bind_path" || true
        fi
        if [ "$snapshot_created" = true ]; then
          zfs destroy "$snapshot" || true
        fi
        exit "$status"
      }
      trap cleanup EXIT INT TERM

      zfs snapshot "$snapshot"
      snapshot_created=true
      if [ ! -d "$snapshot_path" ]; then
        echo "snapshot source path is unavailable" >&2
        exit 1
      fi

      install -d -m 0700 "$bind_path"
      mount --bind "$snapshot_path" "$bind_path"
      mount -o remount,bind,ro "$bind_path"
      bind_mounted=true

      restic backup "$bind_path" \
        --host ${lib.escapeShellArg cfg.backupHost} \
        --tag home \
        --one-file-system \
        --exclude-caches \
        --exclude-file ${excludeFile} \
        --skip-if-unchanged

      restic forget \
        --host ${lib.escapeShellArg cfg.backupHost} \
        --tag home \
        --keep-daily ${toString cfg.retention.daily} \
        --keep-weekly ${toString cfg.retention.weekly} \
        --keep-monthly ${toString cfg.retention.monthly}
    '';
  };
  maintenanceScript = pkgs.writeShellApplication {
    name = "snapshot-restic-home-maintenance";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.restic
      pkgs.util-linux
    ];
    text = ''
      ${resticEnvironment}
      ${repositoryGuard}

      install -d -m 0700 "$RESTIC_CACHE_DIR"
      exec 9>/run/lock/snapshot-restic-home.lock
      flock 9

      restic forget \
        --host ${lib.escapeShellArg cfg.backupHost} \
        --tag home \
        --keep-daily ${toString cfg.retention.daily} \
        --keep-weekly ${toString cfg.retention.weekly} \
        --keep-monthly ${toString cfg.retention.monthly} \
        --prune
      restic check
    '';
  };
  fullCheckScript = pkgs.writeShellApplication {
    name = "snapshot-restic-home-full-check";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.restic
      pkgs.util-linux
    ];
    text = ''
      ${resticEnvironment}
      ${repositoryGuard}

      install -d -m 0700 "$RESTIC_CACHE_DIR"
      exec 9>/run/lock/snapshot-restic-home.lock
      flock 9
      restic check --read-data
    '';
  };
  serviceDefaults = {
    after = ["snapshot-restic-home-prepare.service"];
    requires = ["snapshot-restic-home-prepare.service"];
    serviceConfig = {
      Type = "oneshot";
      CacheDirectory = "snapshot-restic-home";
      CacheDirectoryMode = "0700";
      Nice = 10;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 7;
      TimeoutStartSec = "12h";
      UMask = "0077";
    };
  };
  timerDefaults = {
    wantedBy = ["timers.target"];
    timerConfig = {
      Persistent = false;
      RandomizedDelaySec = "0";
    };
  };
in {
  options.services.snapshot-restic-home = {
    enable = lib.mkEnableOption "snapshot-consistent Restic backup of a home directory";
    sourceDataset = lib.mkOption {
      type = lib.types.str;
      description = "ZFS dataset containing the source home directory.";
    };
    sourceMountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/home";
      description = "Mounted path of the source ZFS dataset.";
    };
    sourceRelativePath = lib.mkOption {
      type = lib.types.str;
      description = "Path within the source dataset to back up.";
    };
    repositoryDataset = lib.mkOption {
      type = lib.types.str;
      description = "Encrypted ZFS dataset used for the local Restic repository.";
    };
    repositoryMountPoint = lib.mkOption {
      type = lib.types.str;
      description = "Mountpoint for the Restic repository dataset.";
    };
    repositoryQuota = lib.mkOption {
      type = lib.types.str;
      default = "300G";
      description = "ZFS quota applied to the Restic repository dataset.";
    };
    passwordFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime file containing the Restic repository password.";
    };
    backupHost = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Stable Restic host label.";
    };
    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 05:50:00";
      description = "systemd calendar expression for the daily backup.";
    };
    excludePatterns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Restic exclude patterns beginning with a slash and relative to the home directory being backed up.";
    };
    retention = {
      daily = lib.mkOption {
        type = lib.types.ints.positive;
        default = 7;
      };
      weekly = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4;
      };
      monthly = lib.mkOption {
        type = lib.types.ints.positive;
        default = 6;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.snapshot-restic-home-prepare = {
      description = "Prepare the encrypted local Restic home repository";
      after = ["zfs-mount.service"];
      requires = ["zfs-mount.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe prepareScript;
        UMask = "0077";
      };
    };

    systemd.services.xyz-home-backup = lib.recursiveUpdate serviceDefaults {
      description = "Back up xyz home from a temporary ZFS snapshot with Restic";
      serviceConfig.ExecStart = lib.getExe backupScript;
    };
    systemd.timers.xyz-home-backup = lib.recursiveUpdate timerDefaults {
      description = "Daily snapshot-consistent Restic home backup";
      timerConfig.OnCalendar = cfg.schedule;
    };

    systemd.services.snapshot-restic-home-maintenance = lib.recursiveUpdate serviceDefaults {
      description = "Prune and verify the Restic home repository";
      serviceConfig.ExecStart = lib.getExe maintenanceScript;
    };
    systemd.timers.snapshot-restic-home-maintenance = lib.recursiveUpdate timerDefaults {
      description = "Weekly Restic home repository maintenance";
      timerConfig.OnCalendar = "Sun *-*-* 07:30:00";
    };

    systemd.services.snapshot-restic-home-full-check = lib.recursiveUpdate serviceDefaults {
      description = "Read and verify all Restic home repository data";
      serviceConfig.ExecStart = lib.getExe fullCheckScript;
    };
    systemd.timers.snapshot-restic-home-full-check = lib.recursiveUpdate timerDefaults {
      description = "Monthly full-data Restic home repository check";
      timerConfig.OnCalendar = "Sun *-*-01..07 09:00:00";
    };
  };
}
