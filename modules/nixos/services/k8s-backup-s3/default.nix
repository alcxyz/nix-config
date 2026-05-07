{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.k8s-backup-s3;
  rustfsPackage = inputs.rustfs.packages.${pkgs.stdenv.hostPlatform.system}.default;
in {
  options.services.k8s-backup-s3 = {
    enable = lib.mkEnableOption "host-level RustFS S3 target for Kubernetes backups";

    dataset = lib.mkOption {
      type = lib.types.str;
      default = "ypool/k8s-backups";
      description = "ZFS dataset used for backup object storage.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/ypool/k8s-backups/rustfs";
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

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the S3 API port on the host firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [rustfsPackage];

    users.users.rustfs = {
      isSystemUser = true;
      uid = 10001;
      group = "rustfs";
      home = cfg.dataDir;
    };
    users.groups.rustfs = {};

    systemd.services.k8s-backup-s3-dataset = {
      description = "Prepare quota-limited ZFS dataset for k8s backups";
      after = [
        "zfs-auto-unlock.service"
        "zfs-mount.service"
      ];
      requires = [
        "zfs-auto-unlock.service"
        "zfs-mount.service"
      ];
      before = ["k8s-backup-rustfs.service"];
      requiredBy = ["k8s-backup-rustfs.service"];
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

        install -d -m 0750 -o rustfs -g rustfs ${lib.escapeShellArg (toString cfg.dataDir)}
      '';
    };

    systemd.services.k8s-backup-rustfs = {
      description = "RustFS backup target for Kubernetes";
      wantedBy = ["multi-user.target"];
      after = [
        "network-online.target"
        "k8s-backup-s3-dataset.service"
      ];
      wants = ["network-online.target"];
      requires = ["k8s-backup-s3-dataset.service"];
      serviceConfig = {
        Type = "simple";
        User = "rustfs";
        Group = "rustfs";
        LoadCredential = [
          "rustfs_access_key:${cfg.accessKeyFile}"
          "rustfs_secret_key:${cfg.secretKeyFile}"
        ];
        ExecStart = "${rustfsPackage}/bin/rustfs server --address=${cfg.apiAddress} --console-enable --console-address=${cfg.consoleAddress} --access-key-file=%d/rustfs_access_key --secret-key-file=%d/rustfs_secret_key ${toString cfg.dataDir}";
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

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [
      (lib.toInt (builtins.elemAt (lib.splitString ":" cfg.apiAddress) 1))
    ];
  };
}
