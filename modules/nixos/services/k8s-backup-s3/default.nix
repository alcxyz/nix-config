{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.k8s-backup-s3;
  rustfsPackage = inputs.rustfs.packages.${pkgs.stdenv.hostPlatform.system}.default;
  localEndpoint = "http://${cfg.apiAddress}";
  mirrorEnabled = cfg.mirrorSourceEndpoint != null;
  apiPort = lib.toInt (lib.last (lib.splitString ":" cfg.apiAddress));
in
{
  options.services.k8s-backup-s3 = {
    enable = lib.mkEnableOption "host-level RustFS S3 target for Kubernetes backups";

    storageMode = lib.mkOption {
      type = lib.types.enum [
        "zfs"
        "mounted-filesystem"
      ];
      default = "zfs";
      description = "Whether the object directory is prepared as ZFS or lives on an existing dedicated mount.";
    };

    storageUnit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Systemd mount unit required when storageMode is mounted-filesystem.";
    };

    dataset = lib.mkOption {
      type = lib.types.str;
      default = "tank/k8s-backups";
      description = "ZFS dataset used for backup object storage.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/tank/k8s-backups/rustfs";
      description = "RustFS object data directory.";
    };

    quota = lib.mkOption {
      type = lib.types.str;
      default = "1T";
      description = "ZFS quota for the backup dataset.";
    };

    apiAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.10:9100";
      description = "LAN address for the S3 API.";
    };

    consoleAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:9101";
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
      default = 10001;
      description = "Stable numeric UID for the RustFS service user.";
    };

    serviceGid = lib.mkOption {
      type = lib.types.int;
      default = 10001;
      description = "Stable numeric GID for the RustFS service group.";
    };

    mirrorSourceEndpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional authoritative S3 endpoint to mirror into this target.";
    };

    mirrorSchedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 06:10:00";
      description = "Calendar schedule for mirroring the authoritative target.";
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
        assertion = cfg.storageMode != "mounted-filesystem" || cfg.storageUnit != null;
        message = "services.k8s-backup-s3.storageUnit is required for mounted-filesystem storage.";
      }
      {
        assertion = cfg.mirrorSourceEndpoint == null || cfg.mirrorSourceEndpoint != localEndpoint;
        message = "The Kubernetes backup source and local S3 endpoints must differ.";
      }
    ];

    environment.systemPackages = [
      pkgs.minio-client
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
      if cfg.storageMode == "zfs" then
        {
          description = "Prepare quota-limited ZFS dataset for k8s backups";
          after = [
            "zfs-auto-unlock.service"
            "zfs-mount.service"
          ];
          requires = [
            "zfs-auto-unlock.service"
            "zfs-mount.service"
          ];
          before = [ "k8s-backup-rustfs.service" ];
          requiredBy = [ "k8s-backup-rustfs.service" ];
          path = [
            pkgs.coreutils
            pkgs.zfs
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            set -euo pipefail

            if ! zfs list -H ${lib.escapeShellArg cfg.dataset} >/dev/null 2>&1; then
              zfs create \
                -o mountpoint=${lib.escapeShellArg (toString cfg.dataDir)} \
                -o quota=${lib.escapeShellArg cfg.quota} \
                -o compression=zstd \
                -o atime=off \
                ${lib.escapeShellArg cfg.dataset}
            else
              zfs set mountpoint=${lib.escapeShellArg (toString cfg.dataDir)} ${lib.escapeShellArg cfg.dataset}
              zfs set quota=${lib.escapeShellArg cfg.quota} ${lib.escapeShellArg cfg.dataset}
              zfs set compression=zstd ${lib.escapeShellArg cfg.dataset}
              zfs set atime=off ${lib.escapeShellArg cfg.dataset}
            fi

            install -d -m 0750 \
              -o ${lib.escapeShellArg cfg.serviceUser} \
              -g ${lib.escapeShellArg cfg.serviceGroup} \
              ${lib.escapeShellArg (toString cfg.dataDir)}
          '';
        }
      else
        {
          description = "Validate the dedicated mounted filesystem for k8s backups";
          after = [ cfg.storageUnit ];
          requires = [ cfg.storageUnit ];
          before = [ "k8s-backup-rustfs.service" ];
          requiredBy = [ "k8s-backup-rustfs.service" ];
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
      after = [
        "network-online.target"
        "k8s-backup-s3-storage.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "k8s-backup-s3-storage.service" ];
      serviceConfig = {
        Type = "simple";
        User = cfg.serviceUser;
        Group = cfg.serviceGroup;
        LoadCredential = [
          "rustfs_access_key:${cfg.accessKeyFile}"
          "rustfs_secret_key:${cfg.secretKeyFile}"
        ];
        ExecStart = "${rustfsPackage}/bin/rustfs server --address=${cfg.apiAddress} --console-enable --console-address=${cfg.consoleAddress} --access-key-file=%d/rustfs_access_key --secret-key-file=%d/rustfs_secret_key ${toString cfg.dataDir}";
        Environment = [
          "RUSTFS_DRIVE_TIMEOUT_PROFILE=high_latency"
          "RUSTFS_SCANNER_ENABLED=${lib.boolToString cfg.scannerEnabled}"
          "RUSTFS_HEAL_ENABLED=${lib.boolToString cfg.healEnabled}"
        ] ++ lib.optional (cfg.runtimeWorkerThreads != null)
          "RUSTFS_RUNTIME_WORKER_THREADS=${toString cfg.runtimeWorkerThreads}";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
        StateDirectory = "k8s-backup-rustfs";
      };
    };

    systemd.services.k8s-backup-s3-mirror = lib.mkIf mirrorEnabled {
      description = "Mirror and verify the authoritative Kubernetes S3 backups";
      after = [
        "network-online.target"
        "k8s-backup-rustfs.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "k8s-backup-rustfs.service" ];
      path = [
        pkgs.coreutils
        pkgs.getent
        pkgs.jq
        pkgs.minio-client
      ];
      serviceConfig = {
        Type = "oneshot";
        LoadCredential = [
          "s3_access_key:${cfg.accessKeyFile}"
          "s3_secret_key:${cfg.secretKeyFile}"
        ];
        TimeoutStartSec = "12h";
        Nice = 15;
        IOSchedulingClass = "idle";
        CPUSchedulingPolicy = "idle";
      };
      script = ''
        set -euo pipefail
        umask 077

        MC_CONFIG_DIR="$(mktemp -d)"
        export MC_CONFIG_DIR
        trap 'rm -rf "$MC_CONFIG_DIR"' EXIT

        import_alias() {
          local name="$1"
          local endpoint="$2"
          local credential_json="$MC_CONFIG_DIR/$name.json"

          jq -n \
            --arg url "$endpoint" \
            --rawfile access "$CREDENTIALS_DIRECTORY/s3_access_key" \
            --rawfile secret "$CREDENTIALS_DIRECTORY/s3_secret_key" \
            '{
              url: $url,
              accessKey: ($access | rtrimstr("\n")),
              secretKey: ($secret | rtrimstr("\n")),
              api: "s3v4",
              path: "auto"
            }' >"$credential_json"
          mc alias import "$name" "$credential_json" >/dev/null
          rm -f "$credential_json"
        }

        import_alias source ${lib.escapeShellArg cfg.mirrorSourceEndpoint}
        import_alias replica ${lib.escapeShellArg localEndpoint}

        inventory_dir="$MC_CONFIG_DIR/inventory"
        mkdir -p "$inventory_dir"

        write_inventory() {
          local alias="$1"
          local bucket="$2"
          local output="$3"

          mc ls --recursive --json "$alias/$bucket" \
            | jq -cS 'select(.status == "success" and .type == "file") | {key, size}' \
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
            key="$(jq -r '.key' <<<"$object")"
            expected_size="$(jq -r '.size' <<<"$object")"

            if replica_stat="$(mc stat --json "replica/$bucket/$key" 2>/dev/null)" \
              && actual_size="$(jq -er 'select(.status == "success") | .size' <<<"$replica_stat")" \
              && [ "$actual_size" = "$expected_size" ]; then
              verified_by_stat=$((verified_by_stat + 1))
            else
              printf '%s\n' "$object" >>"$unresolved"
            fi
          done <"$missing"

          mv "$unresolved" "$missing"
          printf '%s\n' "$verified_by_stat"
        }

        for attempt in $(seq 1 30); do
          if mc ls replica >/dev/null 2>&1; then
            break
          fi
          if [ "$attempt" -eq 30 ]; then
            echo "replica S3 endpoint did not become ready" >&2
            exit 1
          fi
          sleep 2
        done

        mapfile -t buckets < <(mc ls --json source | jq -r 'select(.type == "folder") | .key | rtrimstr("/")')
        if [ "''${#buckets[@]}" -eq 0 ]; then
          echo "authoritative backup target contains no buckets; refusing an empty mirror" >&2
          exit 1
        fi

        for bucket in "''${buckets[@]}"; do
          mc mb --ignore-existing "replica/$bucket"

          bucket_inventory="$(mktemp -d "$inventory_dir/bucket.XXXXXX")"

          for attempt in $(seq 1 5); do
            source_checkpoint="$bucket_inventory/source-checkpoint.jsonl"
            replica_after="$bucket_inventory/replica-after.jsonl"
            missing="$bucket_inventory/missing.jsonl"

            # Capture a finite source checkpoint before mirroring. Backup
            # buckets can receive immutable objects continuously (for example,
            # database WAL), so comparing live aggregate totals after the copy
            # can never converge even when every object observed at the start
            # was replicated correctly.
            write_inventory source "$bucket" "$source_checkpoint"
            mc mirror --overwrite --remove --quiet "source/$bucket" "replica/$bucket" >/dev/null
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
              echo "verified bucket=$bucket checkpoint_bytes=$checkpoint_bytes checkpoint_objects=$checkpoint_objects direct_stat_objects=$verified_by_stat_objects attempts=$attempt"
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
      '';
    };

    systemd.timers.k8s-backup-s3-mirror = lib.mkIf mirrorEnabled {
      description = "Daily independent replica of Kubernetes backups";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.mirrorSchedule;
        Persistent = false;
        RandomizedDelaySec = "0";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ apiPort ];
  };
}
