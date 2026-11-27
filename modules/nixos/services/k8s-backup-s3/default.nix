{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.k8s-backup-s3;
  rustfsPackage =
    inputs.rustfs.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs
    (old: {
      patches = (old.patches or []) ++ [./rustfs-tier-free-version-recovery-switch.patch];
    });
  localEndpoint = "http://${cfg.apiAddress}";
  mirrorEnabled = cfg.mirrorSourceEndpoint != null;
  apiPort = lib.toInt (lib.last (lib.splitString ":" cfg.apiAddress));
  zfsDataset =
    if cfg.dataset == null
    then ""
    else cfg.dataset;
  zfsQuota =
    if cfg.quota == null
    then ""
    else cfg.quota;
  mirrorSchedule =
    if cfg.mirrorSchedule == null
    then ""
    else cfg.mirrorSchedule;
  extraSources = cfg.mirrorExtraSources;
  extraBuckets = lib.concatMap (source: source.buckets) extraSources;
  remoteVariable = name: "RCLONE_CONFIG_${lib.toUpper name}";
  # rclone reads a bare number as KiB/s, so a unit is required.
  bandwidthLimitType = lib.types.strMatching "[0-9]+(\\.[0-9]+)?[BKMGTP]";
  # S3 bucket naming: no slash or empty name can reach the overlap guard or
  # turn a bucket sync into a sync of the remote's root.
  # Also no consecutive dots and no IPv4-address form, as S3 requires.
  bucketNameType =
    lib.types.addCheck (lib.types.strMatching "[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]")
    (name:
      builtins.match ".*\\.\\..*" name
      == null
      && builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" name == null);
  bandwidthArgument = limit:
    if limit == null
    then ""
    else limit;
in {
  options.services.k8s-backup-s3 = {
    enable = lib.mkEnableOption "host-level RustFS S3 target for Kubernetes backups";

    storageMode = lib.mkOption {
      type = lib.types.enum [
        "zfs"
        "mounted-filesystem"
      ];
      description = "Whether the object directory is prepared as ZFS or lives on an existing dedicated mount.";
    };

    storageUnit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Systemd mount unit required when storageMode is mounted-filesystem.";
    };

    dataset = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "ZFS dataset used for backup object storage; required in ZFS mode.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      description = "RustFS object data directory.";
    };

    quota = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "ZFS quota for the backup dataset; required in ZFS mode.";
    };

    apiAddress = lib.mkOption {
      type = lib.types.str;
      description = "LAN address for the S3 API.";
    };

    consoleAddress = lib.mkOption {
      type = lib.types.str;
      description = "Loopback-only RustFS console address.";
    };

    accessKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Secret file containing the RustFS access key.";
    };

    secretKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Secret file containing the RustFS secret key.";
    };

    serviceUser = lib.mkOption {
      type = lib.types.str;
      default = "rustfs";
      description = "Local system user that owns and serves the object tree.";
    };

    serviceGroup = lib.mkOption {
      type = lib.types.str;
      default = "rustfs";
      description = "Local system group that owns and serves the object tree.";
    };

    serviceUid = lib.mkOption {
      type = lib.types.int;
      description = "Stable numeric UID for the RustFS service user.";
    };

    serviceGid = lib.mkOption {
      type = lib.types.int;
      description = "Stable numeric GID for the RustFS service group.";
    };

    mirrorSourceEndpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional authoritative S3 endpoint to mirror into this target. Once a
        verified pass has seen it list a bucket, a later pass that finds it empty
        fails before any change, as a lost or misconfigured source would look.
        To empty it on purpose, remove the default-source-had-buckets file in the
        mirror's state directory (/var/lib/k8s-backup-s3-mirror).
      '';
    };

    mirrorSchedule = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Calendar schedule for mirroring the authoritative target; required when mirroring is enabled.";
    };

    mirrorMaxWorkers = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "Maximum concurrent workers used by each S3 mirror pass.";
    };

    mirrorBandwidthLimit = lib.mkOption {
      type = lib.types.nullOr bandwidthLimitType;
      default = null;
      example = "5M";
      description = ''
        rclone --bwlimit for the copies from mirrorSourceEndpoint, a number with a
        binary unit: B, K, M, G, T or P (bytes, KiB ... PiB per second; 5M is
        5 MiB/s). Null leaves them unlimited. Listings and checks are not limited.
      '';
    };

    mirrorExtraSources = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.strMatching "[a-z][a-z0-9]{0,15}";
            description = "rclone remote name for this source; not source or replica.";
          };
          endpoint = lib.mkOption {
            type = lib.types.str;
            description = "S3 endpoint of this source.";
          };
          buckets = lib.mkOption {
            type = lib.types.nonEmptyListOf bucketNameType;
            description = ''
              Buckets mirrored from this source instead of from mirrorSourceEndpoint.
              The credentials need only list and read them; the source need not
              allow listing its buckets. A pass fails if mirrorSourceEndpoint also
              lists one of them, rather than mirror two sources into one replica
              bucket.
            '';
          };
          accessKeyFile = lib.mkOption {
            type = lib.types.path;
            description = "File holding this source's access key, loaded as a systemd credential.";
          };
          secretKeyFile = lib.mkOption {
            type = lib.types.path;
            description = "File holding this source's secret key, loaded as a systemd credential.";
          };
          bandwidthLimit = lib.mkOption {
            type = lib.types.nullOr bandwidthLimitType;
            default = null;
            example = "10M";
            description = "rclone --bwlimit for the copies from this source, with a unit as in mirrorBandwidthLimit; null leaves them unlimited.";
          };
        };
      });
      default = [];
      description = ''
        Further S3 sources, each mirroring named buckets into this target with its
        own endpoint, credentials and bandwidth limit. Every other bucket still
        comes from mirrorSourceEndpoint, and each pass verifies and snapshots all
        of them together.
      '';
    };

    mirrorChecksumBuckets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["longhorn"];
      description = ''
        Buckets whose mirror sync compares listing checksums instead of
        modification times, which saves a HEAD request per object on each side.
        rclone falls back to size alone for an object with no usable hash, such as
        a multipart upload without MD5 metadata, so list only buckets where a key's
        content cannot change at the same size. Longhorn names each block after
        its content, and its small configuration files are single-part.
      '';
    };

    mirrorFullVerificationDay = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum ["Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun"]);
      default = null;
      description = ''
        Weekday on which a mirror pass reconciles and verifies every object. A pass
        on any other day copies and checks only what the source received since the
        last verified pass for each bucket a full pass has already verified under
        its current source and endpoint, so for those it never lists the replica
        and does not remove objects deleted at the source. Any other bucket gets a
        full sync (with --delete-after) and verification inside that pass: a new
        bucket, one whose source or endpoint changed, one that moved and came back
        or rejoined the plan, and every bucket on the first run after an upgrade
        from a version without these records. A pass also runs in full when no
        verified pass is recorded or the last full one is over a week old, so a
        failed full pass is retried by the next run. With null, every pass runs in
        full. Setting a day changes when objects are verified, not what a full pass
        does.
      '';
    };

    mirrorSnapshotRetention = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = ''
        Number of verified mirror snapshots to retain on the ZFS dataset.
        Zero disables snapshots. Only snapshots locally marked as owned by
        this mirror feature are pruned; other snapshots are preserved.
        The dataset quota covers live objects and all snapshot history. Size
        it for retained and migrated history plus object churn, and monitor
        free space. Pruning follows a verified pass, so an exhausted quota
        requires operator intervention before mirroring can succeed again.
      '';
    };

    scannerEnabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable the RustFS background scanner. Disable this when retention and
        integrity handling are external and continuous bucket scans would only
        add load to a single-disk backup target.
      '';
    };

    healEnabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable RustFS background healing. This has no repair value for a
        single-disk target and can cause the same continuous object walks as
        the scanner.
      '';
    };

    tierFreeVersionRecoveryEnabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable RustFS recovery of remotely tiered free versions. Disable this
        when object tiering is unused; RustFS beta.10 otherwise walks every
        bucket once per minute even when its scanner is disabled.
      '';
    };

    capacityScanIntervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = ''
        Interval between RustFS recursive object-capacity inventories. This
        only refreshes cached capacity reporting and may be lengthened for
        large, low-activity backup targets.
      '';
    };

    alwaysOn = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Keep the RustFS endpoint running independently of consumers. Disable
        this for a replica that should run only while its mirror job needs it.
      '';
    };

    runtimeWorkerThreads = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = ''
        Optional RustFS Tokio worker count. Small backup targets can use a low
        value to avoid idle scheduler overhead from one worker per CPU.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the S3 API port on the host firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          cfg.mirrorSnapshotRetention
          == 0
          || (
            mirrorEnabled && cfg.storageMode == "zfs" && cfg.dataset != null && cfg.dataset != ""
          );
        message = "services.k8s-backup-s3.mirrorSnapshotRetention requires an enabled ZFS mirror with a dataset.";
      }
      {
        assertion = cfg.storageMode != "mounted-filesystem" || cfg.storageUnit != null;
        message = "services.k8s-backup-s3.storageUnit is required for mounted-filesystem storage.";
      }
      {
        assertion = cfg.storageMode != "zfs" || cfg.dataset != null;
        message = "services.k8s-backup-s3.dataset is required for ZFS storage.";
      }
      {
        assertion = cfg.storageMode != "zfs" || cfg.quota != null;
        message = "services.k8s-backup-s3.quota is required for ZFS storage.";
      }
      {
        assertion = cfg.mirrorSourceEndpoint == null || cfg.mirrorSourceEndpoint != localEndpoint;
        message = "The Kubernetes backup source and local S3 endpoints must differ.";
      }
      {
        assertion = cfg.mirrorSourceEndpoint == null || cfg.mirrorSchedule != null;
        message = "services.k8s-backup-s3.mirrorSchedule is required when mirroring is enabled.";
      }
      {
        assertion = extraSources == [] || mirrorEnabled;
        message = "services.k8s-backup-s3.mirrorExtraSources requires mirrorSourceEndpoint.";
      }
      {
        assertion = let
          names = map (source: source.name) extraSources;
        in
          lib.unique names == names && !(builtins.elem "source" names) && !(builtins.elem "replica" names);
        message = "services.k8s-backup-s3.mirrorExtraSources names must be unique and not source or replica.";
      }
      {
        assertion = lib.unique extraBuckets == extraBuckets;
        message = "services.k8s-backup-s3.mirrorExtraSources must not list a bucket twice.";
      }
      {
        assertion = builtins.all (source: source.endpoint != localEndpoint) extraSources;
        message = "A Kubernetes backup mirror source and the local S3 endpoint must differ.";
      }
    ];

    environment.systemPackages = [
      pkgs.rclone
      rustfsPackage
    ];

    users.users.${cfg.serviceUser} = {
      isSystemUser = true;
      uid = cfg.serviceUid;
      group = cfg.serviceGroup;
      home = cfg.dataDir;
    };
    users.groups.${cfg.serviceGroup}.gid = cfg.serviceGid;

    systemd.services.k8s-backup-s3-storage =
      if cfg.storageMode == "zfs"
      then {
        description = "Prepare quota-limited ZFS dataset for k8s backups";
        # An on-demand replica applies new definitions on its next start, so a
        # deploy cannot stop a running mirror through this dependency. Its ZFS
        # units are only ordered and wanted, since a deploy can restart them; the
        # script below refuses to run unless the dataset is really mounted.
        restartIfChanged = cfg.alwaysOn;
        unitConfig.StopWhenUnneeded = !cfg.alwaysOn;
        after = [
          "zfs-auto-unlock.service"
          "zfs-mount.service"
        ];
        requires = lib.optionals cfg.alwaysOn [
          "zfs-auto-unlock.service"
          "zfs-mount.service"
        ];
        wants = lib.optionals (!cfg.alwaysOn) [
          "zfs-auto-unlock.service"
          "zfs-mount.service"
        ];
        before = ["k8s-backup-rustfs.service"];
        requiredBy = ["k8s-backup-rustfs.service"];
        path = [
          pkgs.coreutils
          pkgs.util-linux
          config.boot.zfs.package
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail

          if ! zfs list -H ${lib.escapeShellArg zfsDataset} >/dev/null 2>&1; then
            zfs create \
              -o mountpoint=${lib.escapeShellArg (toString cfg.dataDir)} \
              -o quota=${lib.escapeShellArg zfsQuota} \
              -o compression=zstd \
              -o atime=off \
              ${lib.escapeShellArg zfsDataset}
          else
            zfs set mountpoint=${lib.escapeShellArg (toString cfg.dataDir)} ${lib.escapeShellArg zfsDataset}
            zfs set quota=${lib.escapeShellArg zfsQuota} ${lib.escapeShellArg zfsDataset}
            zfs set compression=zstd ${lib.escapeShellArg zfsDataset}
            zfs set atime=off ${lib.escapeShellArg zfsDataset}
          fi

          data=${lib.escapeShellArg (toString cfg.dataDir)}
          dataset=${lib.escapeShellArg zfsDataset}
          readonly="$(zfs get -H -o value readonly "$dataset")"
          mounted="$(zfs get -H -o value mounted "$dataset")"
          if [ "$readonly" != off ] || [ "$mounted" != yes ]; then
            echo "backup dataset is read-only or unavailable; refusing to prepare the object directory" >&2
            exit 1
          fi

          mount_source="$(findmnt -n -o SOURCE --mountpoint "$data")"
          mount_target="$(findmnt -n -o TARGET --mountpoint "$data")"
          mount_type="$(findmnt -n -o FSTYPE --mountpoint "$data")"
          if [ "$mount_source" != "$dataset" ] || [ "$mount_target" != "$data" ] || [ "$mount_type" != zfs ]; then
            echo "backup dataset is not mounted at the exact object directory; refusing to prepare it" >&2
            exit 1
          fi

          install -d -m 0750 \
            -o ${lib.escapeShellArg cfg.serviceUser} \
            -g ${lib.escapeShellArg cfg.serviceGroup} \
            "$data"
        '';
      }
      else {
        description = "Validate the dedicated mounted filesystem for k8s backups";
        # An on-demand replica applies new definitions on its next start, so a
        # deploy cannot stop a running mirror through this dependency.
        restartIfChanged = cfg.alwaysOn;
        unitConfig.StopWhenUnneeded = !cfg.alwaysOn;
        after = [cfg.storageUnit];
        requires = [cfg.storageUnit];
        before = ["k8s-backup-rustfs.service"];
        requiredBy = ["k8s-backup-rustfs.service"];
        path = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.util-linux
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail

          data=${lib.escapeShellArg (toString cfg.dataDir)}
          root_source="$(findmnt -n -o SOURCE -T /)"
          backup_source="$(findmnt -n -o SOURCE -T "$data")"
          if [ "$root_source" = "$backup_source" ]; then
            echo "$data is on the root filesystem; refusing to start the backup target" >&2
            exit 1
          fi

          install -d -m 0750 \
            -o ${lib.escapeShellArg cfg.serviceUser} \
            -g ${lib.escapeShellArg cfg.serviceGroup} \
            "$data"
          if find "$data" -mindepth 1 -maxdepth 1 ! -user ${lib.escapeShellArg cfg.serviceUser} -print -quit | grep -q .; then
            echo "$data contains objects not owned by ${cfg.serviceUser}; refusing an unsafe partial ownership change" >&2
            exit 1
          fi
        '';
      };

    systemd.services.k8s-backup-rustfs = {
      description = "RustFS backup target for Kubernetes";
      wantedBy = lib.optional cfg.alwaysOn "multi-user.target";
      unitConfig.StopWhenUnneeded = !cfg.alwaysOn;
      restartIfChanged = cfg.alwaysOn;
      after = [
        "network-online.target"
        "k8s-backup-s3-storage.service"
      ];
      wants = ["network-online.target"];
      requires = ["k8s-backup-s3-storage.service"];
      serviceConfig = {
        Type = "simple";
        User = cfg.serviceUser;
        Group = cfg.serviceGroup;
        LoadCredential = [
          "rustfs_access_key:${cfg.accessKeyFile}"
          "rustfs_secret_key:${cfg.secretKeyFile}"
        ];
        ExecStart = "${rustfsPackage}/bin/rustfs server --address=${cfg.apiAddress} --console-enable --console-address=${cfg.consoleAddress} --access-key-file=%d/rustfs_access_key --secret-key-file=%d/rustfs_secret_key ${toString cfg.dataDir}";
        Environment =
          [
            "RUSTFS_DRIVE_TIMEOUT_PROFILE=high_latency"
            "RUSTFS_SCANNER_ENABLED=${lib.boolToString cfg.scannerEnabled}"
            "RUSTFS_HEAL_ENABLED=${lib.boolToString cfg.healEnabled}"
            "RUSTFS_TIER_FREE_VERSION_RECOVERY_ENABLED=${lib.boolToString cfg.tierFreeVersionRecoveryEnabled}"
            "RUSTFS_CAPACITY_SCHEDULED_INTERVAL=${toString cfg.capacityScanIntervalSeconds}"
          ]
          ++ lib.optional (
            cfg.runtimeWorkerThreads != null
          ) "RUSTFS_RUNTIME_WORKER_THREADS=${toString cfg.runtimeWorkerThreads}";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [cfg.dataDir];
        StateDirectory = "k8s-backup-rustfs";
      };
    };

    systemd.services.k8s-backup-s3-mirror = lib.mkIf mirrorEnabled {
      description = "Mirror and verify the authoritative Kubernetes S3 backups";
      # A run can take hours. Restarting it would discard that work and make
      # switch-to-configuration wait for the whole oneshot to finish. The next
      # timer run picks up a changed definition.
      restartIfChanged = false;
      after = [
        "network-online.target"
        "k8s-backup-rustfs.service"
      ];
      wants = ["network-online.target"];
      requires = ["k8s-backup-rustfs.service"];
      path =
        [
          pkgs.coreutils
          pkgs.getent
          pkgs.gnugrep
          pkgs.jq
          pkgs.rclone
        ]
        ++ lib.optional (cfg.mirrorSnapshotRetention > 0) config.boot.zfs.package;
      serviceConfig = {
        Type = "oneshot";
        LoadCredential =
          [
            "s3_access_key:${cfg.accessKeyFile}"
            "s3_secret_key:${cfg.secretKeyFile}"
          ]
          ++ lib.concatMap (source: [
            "source_${source.name}_access_key:${source.accessKeyFile}"
            "source_${source.name}_secret_key:${source.secretKeyFile}"
          ])
          extraSources;
        StateDirectory = "k8s-backup-s3-mirror";
        TimeoutStartSec = "12h";
        Nice = 15;
        IOSchedulingClass = "idle";
        CPUSchedulingPolicy = "idle";
      };
      script = ''
        set -euo pipefail
        umask 077

        pass_started="$(date -u +%s)"
        full_verification_day=${lib.escapeShellArg (
          if cfg.mirrorFullVerificationDay == null
          then ""
          else cfg.mirrorFullVerificationDay
        )}

        read_state() {
          local value=""
          if [ -f "$STATE_DIRECTORY/$1" ]; then
            value="$(cat "$STATE_DIRECTORY/$1")"
          fi
          # A missing, damaged or implausible record only costs a full pass. A time
          # ahead of now, say from a clock since corrected, would select nothing.
          case "$value" in
            "" | 0* | *[!0-9]* | ???????????*)
              echo 0
              ;;
            *)
              if [ "$value" -le 3600 ] || [ "$value" -gt "$pass_started" ]; then
                echo 0
              else
                echo "$value"
              fi
              ;;
          esac
        }

        write_state() {
          printf '%s\n' "$pass_started" >"$STATE_DIRECTORY/$1.tmp"
          mv "$STATE_DIRECTORY/$1.tmp" "$STATE_DIRECTORY/$1"
        }

        last_verified="$(read_state last-verified)"
        last_full="$(read_state last-full)"
        pass_scope=full
        recent_since=0
        if [ -n "$full_verification_day" ] && [ "$last_verified" -gt 0 ]; then
          # Start from the last verified pass, not a fixed age, so that a killed
          # or missed run cannot leave a gap. The hour allows for clock skew.
          recent_since=$((last_verified - 3600))
          if [ "$(LC_ALL=C date +%a)" != "$full_verification_day" ] \
            && [ ! -e "$STATE_DIRECTORY/full-pending" ] \
            && [ $((pass_started - last_full)) -lt $((7 * 86400 + 43200)) ]; then
            pass_scope=incremental
          fi
        fi
        if [ "$pass_scope" = full ]; then
          # Stays until a full pass succeeds, so that a failed one is retried by the
          # next run however recent the last successful one was.
          : >"$STATE_DIRECTORY/full-pending"
        fi
        echo "mirror pass scope=$pass_scope"
        # Per bucket, the marker of the assignment a full pass last verified.
        initialized_dir="$STATE_DIRECTORY/initialized"
        mkdir -p "$initialized_dir"

        runtime_dir="$(mktemp -d)"
        trap 'rm -rf "$runtime_dir"' EXIT

        # Keep credentials out of argv and persistent client configuration.
        # Both endpoints use the existing systemd credential files.
        export RCLONE_CONFIG="$runtime_dir/rclone.conf"
        : >"$RCLONE_CONFIG"
        # Credentials go to each remote: rclone treats RCLONE_S3_* as flags, which
        # would override every remote's own keys.
        RCLONE_CONFIG_SOURCE_ACCESS_KEY_ID="$(cat "$CREDENTIALS_DIRECTORY/s3_access_key")"
        RCLONE_CONFIG_SOURCE_SECRET_ACCESS_KEY="$(cat "$CREDENTIALS_DIRECTORY/s3_secret_key")"
        RCLONE_CONFIG_REPLICA_ACCESS_KEY_ID="$RCLONE_CONFIG_SOURCE_ACCESS_KEY_ID"
        RCLONE_CONFIG_REPLICA_SECRET_ACCESS_KEY="$RCLONE_CONFIG_SOURCE_SECRET_ACCESS_KEY"
        export RCLONE_CONFIG_SOURCE_ACCESS_KEY_ID RCLONE_CONFIG_SOURCE_SECRET_ACCESS_KEY
        export RCLONE_CONFIG_REPLICA_ACCESS_KEY_ID RCLONE_CONFIG_REPLICA_SECRET_ACCESS_KEY
        export RCLONE_S3_PROVIDER=Other RCLONE_S3_ENV_AUTH=false
        export RCLONE_S3_FORCE_PATH_STYLE=true
        export RCLONE_CONFIG_SOURCE_TYPE=s3 RCLONE_CONFIG_REPLICA_TYPE=s3
        export RCLONE_CONFIG_SOURCE_ENDPOINT=${lib.escapeShellArg cfg.mirrorSourceEndpoint}
        export RCLONE_CONFIG_REPLICA_ENDPOINT=${lib.escapeShellArg localEndpoint}
        ${lib.concatMapStrings (source: let
            variable = remoteVariable source.name;
          in ''
            export ${variable}_TYPE=s3
            export ${variable}_ENDPOINT=${lib.escapeShellArg source.endpoint}
            ${variable}_ACCESS_KEY_ID="$(cat "$CREDENTIALS_DIRECTORY/source_${source.name}_access_key")"
            ${variable}_SECRET_ACCESS_KEY="$(cat "$CREDENTIALS_DIRECTORY/source_${source.name}_secret_key")"
            export ${variable}_ACCESS_KEY_ID ${variable}_SECRET_ACCESS_KEY
          '')
          extraSources}

        rclone() {
          command rclone --quiet --stats 0 --retries 3 --low-level-retries 10 "$@"
        }

        # The same client settings, recording each object's outcome in a file.
        rclone_logged() {
          local log="$1"
          shift
          command rclone --log-level INFO --log-file "$log" --stats 0 --retries 3 --low-level-retries 10 "$@"
        }

        inventory_dir="$runtime_dir/inventory"
        mkdir -p "$inventory_dir"

        write_inventory() {
          local alias="$1"
          local bucket="$2"
          local output="$3"
          shift 3

          rclone lsjson --recursive --files-only --no-modtime --no-mimetype "$@" "$alias:$bucket" \
            | jq -cS '.[] | select(.IsDir == false) | {key: .Path, size: .Size}' \
            | LC_ALL=C sort >"$output"
        }

        inventory_stats() {
          jq -c -s '{
            objects: length,
            bytes: (map(.size) | add // 0)
          }' "$1"
        }

        verify_listing_gaps() {
          local bucket="$1"
          local missing="$2"
          local unresolved="$3"
          local object key expected_size replica_stat actual_size
          local verified_by_stat=0

          : >"$unresolved"
          while IFS= read -r object; do
            # A sentinel preserves trailing newlines in object names.
            key="$(jq -r '.key + "/"' <<<"$object")"
            key="''${key%/}"
            expected_size="$(jq -r '.size' <<<"$object")"

            # --stat resolves the exact object independently of recursive
            # listings. Missing S3 objects may be reported as directories.
            if replica_stat="$(rclone lsjson --stat --files-only --no-modtime --no-mimetype "replica:$bucket/$key" 2>/dev/null)" \
              && actual_size="$(jq -er 'select(.IsDir == false) | .Size' <<<"$replica_stat")" \
              && [ "$actual_size" = "$expected_size" ]; then
              verified_by_stat=$((verified_by_stat + 1))
            else
              printf '%s\n' "$object" >>"$unresolved"
            fi
          done <"$missing"

          mv "$unresolved" "$missing"
          printf '%s\n' "$verified_by_stat"
        }

        # Measure the age as each command starts, so that both select from the same
        # point in time.
        recent_filter() {
          recent_args=(
            --max-age "$(($(date -u +%s) - recent_since))s"
            --use-server-modtime
            --no-unicode-normalization
          )
        }

        # Copy what the source received since the last verified pass, then prove the
        # captured inventory arrived. Buckets can receive objects continuously, so
        # comparing against the live source again could fail on anything uploaded
        # after the copy listed it. Copy unconditionally rather than comparing: a
        # comparison could fall back to size alone and keep a stale object, and
        # these are mostly new anyway. --no-traverse avoids listing the replica.
        copy_recent() {
          local bucket="$1"
          local inventory="$2"
          local recent="$inventory/recent.jsonl"
          local missing="$inventory/recent-missing.jsonl"
          local attempt recent_args recent_stats missing_objects

          for attempt in $(seq 1 5); do
            recent_filter
            write_inventory "$source_alias" "$bucket" "$recent" "''${recent_args[@]}"
            recent_stats="$(inventory_stats "$recent")"

            recent_filter
            if rclone copy --ignore-times --no-traverse --metadata "''${recent_args[@]}" \
              "''${bandwidth_args[@]}" \
              --transfers ${toString cfg.mirrorMaxWorkers} \
              --checkers ${toString cfg.mirrorMaxWorkers} \
              --s3-upload-concurrency 1 --multi-thread-streams 0 \
              "$source_alias:$bucket" "replica:$bucket" >/dev/null; then
              cp "$recent" "$missing"
              verify_listing_gaps "$bucket" "$missing" "$inventory/recent-unresolved.jsonl" >/dev/null
              missing_objects="$(wc -l <"$missing" | tr -d ' ')"
              if [ "$missing_objects" -eq 0 ]; then
                echo "verified-recent bucket=$bucket recent_bytes=$(jq -r '.bytes' <<<"$recent_stats") recent_objects=$(jq -r '.objects' <<<"$recent_stats") attempts=$attempt"
                return 0
              fi
              echo "recent copy of bucket $bucket left $missing_objects object(s) missing on attempt $attempt" >&2
            fi

            if [ "$attempt" -eq 5 ]; then
              echo "recent copy failed for bucket $bucket after $attempt attempts" >&2
              exit 1
            fi
            sleep 2
          done
        }

        for attempt in $(seq 1 30); do
          if rclone lsjson --dirs-only replica: >/dev/null 2>&1; then
            break
          fi
          if [ "$attempt" -eq 30 ]; then
            echo "replica S3 endpoint did not become ready" >&2
            exit 1
          fi
          sleep 2
        done

        # Keep the listing in a checked pipeline. Process substitution would
        # hide an endpoint failure from mapfile and could accept a partial list.
        rclone lsjson --dirs-only source: \
          | jq -r '.[] | select(.IsDir == true) | .Path' >"$inventory_dir/buckets"
        mapfile -t buckets <"$inventory_dir/buckets"
        # The default source once listed buckets in a verified pass: an empty
        # listing now is far more likely a lost or misconfigured source than an
        # intended change, so refuse before any change. An operator who empties
        # it on purpose removes this record.
        if [ "''${#buckets[@]}" -eq 0 ] && [ -e "$STATE_DIRECTORY/default-source-had-buckets" ]; then
          echo "the default backup source lists no buckets, but a verified pass saw some; refusing (remove $STATE_DIRECTORY/default-source-had-buckets if it was emptied on purpose)" >&2
          exit 1
        fi

        # Each bucket's source remote and bandwidth limit. A bucket that another
        # source owns must not also come from the default one: two sources
        # syncing into one replica bucket would delete each other's objects.
        plan_sources=()
        plan_endpoints=()
        plan_buckets=()
        plan_limits=()
        extra_buckets=(${lib.escapeShellArgs extraBuckets})
        for bucket in "''${buckets[@]}"; do
          for owned in "''${extra_buckets[@]}"; do
            if [ "$bucket" = "$owned" ]; then
              echo "bucket $bucket is on the default source but mirrored from another source; refusing" >&2
              exit 1
            fi
          done
          plan_sources+=(source)
          plan_endpoints+=("$RCLONE_CONFIG_SOURCE_ENDPOINT")
          plan_buckets+=("$bucket")
          plan_limits+=(${lib.escapeShellArg (bandwidthArgument cfg.mirrorBandwidthLimit)})
        done
        ${lib.concatMapStrings (source:
          lib.concatMapStrings (bucket: ''
            plan_sources+=(${source.name})
            plan_endpoints+=(${lib.escapeShellArg source.endpoint})
            plan_buckets+=(${lib.escapeShellArg bucket})
            plan_limits+=(${lib.escapeShellArg (bandwidthArgument source.bandwidthLimit)})
          '')
          source.buckets)
        extraSources}
        # On the combined plan: an empty default source is fine while another
        # source supplies buckets, but a pass with nothing to mirror is refused.
        if [ "''${#plan_buckets[@]}" -eq 0 ]; then
          echo "the backup sources contain no buckets; refusing an empty mirror" >&2
          exit 1
        fi

        # A bucket that leaves the plan loses its markers before any sync. Other
        # buckets keep advancing last-verified meanwhile, so if it comes back an
        # incremental pass would miss what it received while out; without a
        # marker it gets a full pass instead.
        planned_markers=()
        for bucket in "''${plan_buckets[@]}"; do
          planned_markers+=("$(printf '%s' "$bucket" | sha256sum | cut -d ' ' -f 1)")
        done
        for existing in "$initialized_dir"/*; do
          [ -e "$existing" ] || continue
          keep=false
          for planned in "''${planned_markers[@]}"; do
            if [ "''${existing##*/}" = "$planned" ]; then
              keep=true
            fi
          done
          if [ "$keep" = false ]; then
            rm -rf -- "$existing"
          fi
        done

        for index in "''${!plan_buckets[@]}"; do
          source_alias="''${plan_sources[$index]}"
          bucket="''${plan_buckets[$index]}"
          bandwidth_args=()
          if [ -n "''${plan_limits[$index]}" ]; then
            bandwidth_args=(--bwlimit "''${plan_limits[$index]}")
          fi
          # A bucket gets a full pass until one has verified it under its current
          # assignment (remote, endpoint), whatever the pass scope: an incremental
          # pass copies only recent objects and would never bring over the older
          # ones of a new source, a repointed endpoint or a new bucket. Each
          # bucket has a directory holding the marker of the assignment a full
          # pass last verified. Every other assignment's marker goes before
          # anything touches the bucket's replica: a sync from this assignment
          # may delete objects only the other one had, so after it, even a
          # failed one, going back must take a full pass. Names are digests, so
          # no bucket name or endpoint becomes a path.
          bucket_markers="$initialized_dir/$(printf '%s' "$bucket" | sha256sum | cut -d ' ' -f 1)"
          marker_name="$(printf '%s\n%s\n%s' "$source_alias" "''${plan_endpoints[$index]}" "$bucket" | sha256sum | cut -d ' ' -f 1)"
          marker="$bucket_markers/$marker_name"
          if [ -d "$bucket_markers" ]; then
            for other in "$bucket_markers"/*; do
              if [ "$other" != "$marker" ]; then
                rm -f -- "$other"
              fi
            done
          fi
          bucket_scope="$pass_scope"
          if [ ! -e "$marker" ]; then
            bucket_scope=full
          fi
          echo "mirror source=$source_alias bucket=$bucket scope=$bucket_scope bwlimit=''${plan_limits[$index]:-none}"
          rclone mkdir "replica:$bucket"

          bucket_inventory="$(mktemp -d "$inventory_dir/bucket.XXXXXX")"

          # A full pass does this too, so that what its reconcile still has to
          # copy shows whether the incremental passes have been missing objects.
          if [ "$recent_since" -gt 0 ]; then
            copy_recent "$bucket" "$bucket_inventory"
          fi
          if [ "$bucket_scope" = incremental ]; then
            continue
          fi

          for attempt in $(seq 1 5); do
            source_checkpoint="$bucket_inventory/source-checkpoint.jsonl"
            replica_after="$bucket_inventory/replica-after.jsonl"
            missing="$bucket_inventory/missing.jsonl"

            # Capture a finite source checkpoint before mirroring. Backup
            # buckets can receive immutable objects continuously (for example,
            # database WAL), so comparing live aggregate totals after the copy
            # can never converge even when every object observed at the start
            # was replicated correctly.
            write_inventory "$source_alias" "$bucket" "$source_checkpoint"
            # Retry transient requests before the bounded full-pass retry.
            # Limit transfer/check workers and multipart fan-out independently
            # so a few large objects cannot multiply upload concurrency.
            # Preserve restoration metadata and distinguish exact S3 keys,
            # including canonically equivalent Unicode spellings. See
            # mirrorChecksumBuckets for which buckets may compare checksums.
            comparison=()
            for checksum_bucket in ${lib.escapeShellArgs cfg.mirrorChecksumBuckets}; do
              if [ "$bucket" = "$checksum_bucket" ]; then
                comparison=(--checksum)
              fi
            done
            sync_log="$bucket_inventory/sync.$attempt.log"
            sync_status=0
            rclone_logged "$sync_log" sync "''${comparison[@]}" --delete-after --metadata --no-unicode-normalization \
              "''${bandwidth_args[@]}" \
              --transfers ${toString cfg.mirrorMaxWorkers} \
              --checkers ${toString cfg.mirrorMaxWorkers} \
              --s3-upload-concurrency 1 --multi-thread-streams 0 \
              "$source_alias:$bucket" "replica:$bucket" >/dev/null || sync_status=$?
            # What --quiet would have shown, including errors a retry then recovered.
            grep -E '(ERROR|CRITICAL) *:' "$sync_log" >&2 || true
            if [ "$sync_status" -ne 0 ]; then
              if [ "$attempt" -eq 5 ]; then
                echo "mirror failed for bucket $bucket after $attempt attempts" >&2
                exit 1
              fi

              echo "mirror failed for bucket $bucket on attempt $attempt; retrying the resumable copy" >&2
              sleep 2
              continue
            fi
            write_inventory replica "$bucket" "$replica_after"
            LC_ALL=C comm -23 "$source_checkpoint" "$replica_after" >"$missing"

            # A freshly copied object can be directly readable before it is
            # visible through a cached recursive listing. Close only those
            # listing gaps whose exact key and checkpointed size can be proven
            # with an independent S3 stat; everything else remains missing.
            verified_by_stat_objects="$(
              verify_listing_gaps \
                "$bucket" \
                "$missing" \
                "$bucket_inventory/unresolved.jsonl"
            )"

            missing_objects="$(wc -l <"$missing" | tr -d ' ')"
            if [ "$missing_objects" -eq 0 ]; then
              checkpoint_stats="$(inventory_stats "$source_checkpoint")"
              checkpoint_bytes="$(jq -r '.bytes' <<<"$checkpoint_stats")"
              checkpoint_objects="$(jq -r '.objects' <<<"$checkpoint_stats")"
              # Copies here beyond objects uploaded during this pass are objects
              # that earlier incremental passes missed.
              reconciled_copies="$(cat "$bucket_inventory"/sync.*.log | grep -c ': Copied (' || true)"
              reconciled_deletes="$(cat "$bucket_inventory"/sync.*.log | grep -c ': Deleted' || true)"
              echo "verified bucket=$bucket checkpoint_bytes=$checkpoint_bytes checkpoint_objects=$checkpoint_objects direct_stat_objects=$verified_by_stat_objects attempts=$attempt reconciled_copies=$reconciled_copies reconciled_deletes=$reconciled_deletes"
              mkdir -p "$bucket_markers"
              : >"$marker"
              break
            fi

            if [ "$attempt" -eq 5 ]; then
              echo "replica verification failed for bucket $bucket after $attempt attempts: checkpoint_missing_objects=$missing_objects" >&2
              exit 1
            fi

            echo "bucket $bucket checkpoint still has $missing_objects missing object(s) after attempt $attempt; reconciling the delta" >&2
            sleep 2
          done
        done

        # Every bucket passed. A snapshot failure below still fails the service,
        # but does not make the next pass copy this one's objects again.
        write_state last-verified
        if [ "''${#buckets[@]}" -gt 0 ]; then
          : >"$STATE_DIRECTORY/default-source-had-buckets"
        fi
        if [ "$pass_scope" = full ]; then
          write_state last-full
          rm -f "$STATE_DIRECTORY/full-pending"
        fi

        ${lib.optionalString (cfg.mirrorSnapshotRetention > 0) ''
          # Snapshot only after every bucket has passed verification. Mark
          # ownership atomically with creation, independent of snapshot names.
          snapshot_dataset=${lib.escapeShellArg zfsDataset}
          snapshot_property=org.nix-config:k8s-backup-s3-mirror
          snapshot_name="$snapshot_dataset@k8s-backup-s3-mirror-$(date -u +%Y%m%dT%H%M%S.%NZ)"
          zfs snapshot -o "$snapshot_property=verified" -o "$snapshot_property-scope=$pass_scope" "$snapshot_name"

          # Use checked commands rather than process substitution so a failed
          # inventory/property read fails the service before pruning anything.
          zfs list -H -t snapshot -o name -s creation -s name -d 1 "$snapshot_dataset" >"$runtime_dir/snapshots"
          owned_snapshots=()
          while IFS= read -r snapshot; do
            # Limit ownership to this dataset, never a descendant's snapshots.
            [[ "$snapshot" == "$snapshot_dataset@"* ]] || continue
            ownership="$(zfs get -H -o value,source "$snapshot_property" "$snapshot")"
            if [ "$ownership" = $'verified\tlocal' ]; then
              owned_snapshots+=("$snapshot")
            fi
          done <"$runtime_dir/snapshots"

          prune_count=$((''${#owned_snapshots[@]} - ${toString cfg.mirrorSnapshotRetention}))
          for ((index = 0; index < prune_count; index++)); do
            zfs destroy "''${owned_snapshots[$index]}"
          done
        ''}
      '';
    };

    systemd.timers.k8s-backup-s3-mirror = lib.mkIf mirrorEnabled {
      description = "Daily independent replica of Kubernetes backups";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = mirrorSchedule;
        Persistent = false;
        RandomizedDelaySec = "0";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [apiPort];
  };
}
