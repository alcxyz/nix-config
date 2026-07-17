{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.k8s-backup-replica;
  rustfsPackage = inputs.rustfs.packages.${pkgs.stdenv.hostPlatform.system}.default;
  replicaEndpoint = "http://${cfg.apiAddress}";
  apiPort = lib.toInt (lib.last (lib.splitString ":" cfg.apiAddress));
in
{
  options.services.k8s-backup-replica = {
    enable = lib.mkEnableOption "independent host-level replica of the Kubernetes S3 backup target";

    sourceEndpoint = lib.mkOption {
      type = lib.types.str;
      description = "S3 endpoint to mirror.";
    };

    apiAddress = lib.mkOption {
      type = lib.types.str;
      description = "LAN address for the replica S3 API.";
    };

    consoleAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:9201";
      description = "Loopback-only RustFS console address.";
    };

    storageUnit = lib.mkOption {
      type = lib.types.str;
      description = "Systemd unit that mounts the dedicated backup filesystem.";
    };

    dataRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/k8s-backup-replica";
      description = "Dedicated ext4 mount containing replica data.";
    };

    accessKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "File containing the S3 access key used by both backup targets.";
    };

    secretKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "File containing the S3 secret key used by both backup targets.";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 06:10:00";
      description = "Calendar schedule for mirroring the primary backup target.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the replica S3 API port on the host firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.sourceEndpoint != replicaEndpoint;
        message = "The Kubernetes backup source and replica endpoints must differ.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.dataRoot;
        message = "services.k8s-backup-replica.dataRoot must be an absolute path.";
      }
    ];

    environment.systemPackages = [
      pkgs.minio-client
      rustfsPackage
    ];

    users.users.k8s-backup-replica = {
      isSystemUser = true;
      group = "k8s-backup-replica";
      home = "${cfg.dataRoot}/data";
    };
    users.groups.k8s-backup-replica = { };

    systemd.services.k8s-backup-replica-prepare = {
      description = "Prepare the dedicated Kubernetes backup replica filesystem";
      after = [ cfg.storageUnit ];
      requires = [ cfg.storageUnit ];
      before = [ "k8s-backup-replica-rustfs.service" ];
      requiredBy = [ "k8s-backup-replica-rustfs.service" ];
      path = [
        pkgs.coreutils
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        root=${lib.escapeShellArg cfg.dataRoot}
        data="$root/data"

        if [ "$(findmnt -n -o FSTYPE -T "$root")" != ext4 ]; then
          echo "$root is not backed by ext4; refusing to place backups on the root filesystem" >&2
          exit 1
        fi

        root_source="$(findmnt -n -o SOURCE -T /)"
        backup_source="$(findmnt -n -o SOURCE -T "$root")"
        if [ "$root_source" = "$backup_source" ]; then
          echo "$root is on the root filesystem; refusing to start the backup replica" >&2
          exit 1
        fi

        install -d -m 0750 -o k8s-backup-replica -g k8s-backup-replica "$data"
      '';
    };

    systemd.services.k8s-backup-replica-rustfs = {
      description = "Independent RustFS replica of Kubernetes backups";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "k8s-backup-replica-prepare.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "k8s-backup-replica-prepare.service" ];
      serviceConfig = {
        Type = "simple";
        User = "k8s-backup-replica";
        Group = "k8s-backup-replica";
        LoadCredential = [
          "rustfs_access_key:${cfg.accessKeyFile}"
          "rustfs_secret_key:${cfg.secretKeyFile}"
        ];
        ExecStart = "${rustfsPackage}/bin/rustfs server --address=${cfg.apiAddress} --console-enable --console-address=${cfg.consoleAddress} --access-key-file=%d/rustfs_access_key --secret-key-file=%d/rustfs_secret_key ${cfg.dataRoot}/data";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "${cfg.dataRoot}/data" ];
        StateDirectory = "k8s-backup-replica-rustfs";
      };
    };

    systemd.services.k8s-backup-replica-sync = {
      description = "Mirror and verify Kubernetes S3 backups on xev";
      after = [
        "network-online.target"
        "k8s-backup-replica-rustfs.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "k8s-backup-replica-rustfs.service" ];
      path = [
        pkgs.coreutils
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

        MC_CONFIG_DIR="$(mktemp -d)"
        export MC_CONFIG_DIR
        trap 'rm -rf "$MC_CONFIG_DIR"' EXIT

        access_key="$(cat "$CREDENTIALS_DIRECTORY/s3_access_key")"
        secret_key="$(cat "$CREDENTIALS_DIRECTORY/s3_secret_key")"
        mc alias set primary ${lib.escapeShellArg cfg.sourceEndpoint} "$access_key" "$secret_key"
        mc alias set replica ${lib.escapeShellArg replicaEndpoint} "$access_key" "$secret_key"

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

        mapfile -t buckets < <(mc ls --json primary | jq -r 'select(.type == "folder") | .key | rtrimstr("/")')
        if [ "''${#buckets[@]}" -eq 0 ]; then
          echo "primary backup target contains no buckets; refusing an empty mirror" >&2
          exit 1
        fi

        for bucket in "''${buckets[@]}"; do
          mc mb --ignore-existing "replica/$bucket"
          mc mirror --overwrite --remove "primary/$bucket" "replica/$bucket"

          primary_stats="$(mc du --json "primary/$bucket")"
          replica_stats="$(mc du --json "replica/$bucket")"
          primary_size="$(jq -r '.size' <<<"$primary_stats")"
          replica_size="$(jq -r '.size' <<<"$replica_stats")"
          primary_objects="$(jq -r '.objects' <<<"$primary_stats")"
          replica_objects="$(jq -r '.objects' <<<"$replica_stats")"
          if [ "$primary_size" != "$replica_size" ] || [ "$primary_objects" != "$replica_objects" ]; then
            echo "replica verification failed for bucket $bucket: source=$primary_size bytes/$primary_objects objects replica=$replica_size bytes/$replica_objects objects" >&2
            exit 1
          fi
        done
      '';
    };

    systemd.timers.k8s-backup-replica-sync = {
      description = "Daily independent replica of Kubernetes backups";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = false;
        RandomizedDelaySec = "0";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ apiPort ];
  };
}
