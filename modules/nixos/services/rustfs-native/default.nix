{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.rustfs-native;
  dataDir = toString cfg.dataDir;
  endpointHost = endpoint:
    lib.hasInfix "://${cfg.localEndpointHost}:" endpoint
    || lib.hasInfix "://${cfg.localEndpointHost}/" endpoint;
in {
  options.services.rustfs-native = {
    enable = lib.mkEnableOption "native distributed RustFS object storage";

    package = lib.mkOption {
      type = lib.types.package;
      description = "RustFS package selected and qualified by the caller.";
    };

    endpoints = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      description = "Ordered distributed RustFS volume URLs, identical on every member.";
      example = [
        "http://node-a.example.invalid:9000/var/lib/rustfs-app"
        "http://node-b.example.invalid:9000/var/lib/rustfs-app"
        "http://node-c.example.invalid:9000/var/lib/rustfs-app"
      ];
    };

    localEndpointHost = lib.mkOption {
      type = lib.types.str;
      description = "Host name used by this member in endpoints.";
      example = "node-a.example.invalid";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      description = "Absolute local directory for this member's object data.";
      example = "/var/lib/rustfs-app";
    };

    mountPoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional mount point that must be mounted before the data directory is created.";
    };

    apiAddress = lib.mkOption {
      type = lib.types.str;
      default = ":9000";
      description = "RustFS API listen address.";
    };

    accessKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "Already activated file containing the RustFS access key.";
    };

    secretKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "Already activated file containing the RustFS secret key.";
    };

    console = {
      enable = lib.mkEnableOption "RustFS administrative console";
      address = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1:9001";
        description = "RustFS console listen address when enabled.";
      };
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "rustfs-app";
      description = "Dedicated local system user for the application object store.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "rustfs-app";
      description = "Dedicated local system group for the application object store.";
    };

    uid = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Optional stable numeric UID for existing storage ownership.";
    };

    gid = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Optional stable numeric GID for existing storage ownership.";
    };

    startupTopologyWaitMode = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum ["orchestrated"]);
      default = null;
      description = "Optional RustFS startup mode for orchestrated peer discovery.";
    };

    memoryHigh = lib.mkOption {
      type = lib.types.str;
      default = "2G";
      description = "Soft systemd memory pressure threshold for the RustFS service.";
    };

    cpuWeight = lib.mkOption {
      type = lib.types.ints.between 1 10000;
      default = 100;
      description = "Relative systemd CPU scheduling weight for the RustFS service.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" dataDir && dataDir != "/";
        message = "services.rustfs-native.dataDir must be an absolute directory other than /.";
      }
      {
        assertion = cfg.mountPoint == null || (lib.hasPrefix "/" cfg.mountPoint && cfg.mountPoint != "/");
        message = "services.rustfs-native.mountPoint must be an absolute directory other than /.";
      }
      {
        assertion =
          cfg.mountPoint == null || dataDir == cfg.mountPoint || lib.hasPrefix "${cfg.mountPoint}/" dataDir;
        message = "services.rustfs-native.dataDir must be inside mountPoint.";
      }
      {
        assertion = cfg.localEndpointHost != "" && lib.any endpointHost cfg.endpoints;
        message = "services.rustfs-native.localEndpointHost must identify a member of endpoints.";
      }
      {
        assertion =
          lib.all (
            endpoint: builtins.match "https?://[^[:space:]]+" endpoint != null
          )
          cfg.endpoints;
        message = "services.rustfs-native.endpoints must be HTTP(S) volume URLs without whitespace.";
      }
      {
        assertion = lib.length (lib.unique cfg.endpoints) == lib.length cfg.endpoints;
        message = "services.rustfs-native.endpoints must be unique.";
      }
      {
        assertion = lib.all (path: lib.hasPrefix "/" path) [
          cfg.accessKeyFile
          cfg.secretKeyFile
        ];
        message = "services.rustfs-native credential file paths must be absolute.";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = dataDir;
      uid = lib.mkIf (cfg.uid != null) cfg.uid;
    };
    users.groups.${cfg.group}.gid = lib.mkIf (cfg.gid != null) cfg.gid;

    systemd.services.rustfs-native = {
      description = "Native distributed RustFS object storage";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      unitConfig.RequiresMountsFor = [dataDir] ++ lib.optional (cfg.mountPoint != null) cfg.mountPoint;
      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        Group = cfg.group;
        LoadCredential = [
          "rustfs_access_key:${cfg.accessKeyFile}"
          "rustfs_secret_key:${cfg.secretKeyFile}"
        ];
        ExecStartPre =
          lib.optional (
            cfg.mountPoint != null
          ) "+${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg cfg.mountPoint}"
          ++ [
            "+${pkgs.coreutils}/bin/install -d -m 0750 -o ${lib.escapeShellArg cfg.user} -g ${lib.escapeShellArg cfg.group} ${lib.escapeShellArg dataDir}"
          ];
        ExecStart = lib.concatStringsSep " " (
          [
            "${cfg.package}/bin/rustfs"
            "server"
            (lib.escapeShellArg "--address=${cfg.apiAddress}")
            "--access-key-file=%d/rustfs_access_key"
            "--secret-key-file=%d/rustfs_secret_key"
          ]
          ++ lib.optionals cfg.console.enable [
            "--console-enable"
            (lib.escapeShellArg "--console-address=${cfg.console.address}")
          ]
        );
        Environment =
          [
            "RUSTFS_VOLUMES=${lib.concatStringsSep " " cfg.endpoints}"
            "RUSTFS_LOCAL_ENDPOINT_HOST=${cfg.localEndpointHost}"
            "RUSTFS_CONSOLE_ENABLE=${lib.boolToString cfg.console.enable}"
          ]
          ++ lib.optional (
            cfg.startupTopologyWaitMode != null
          ) "RUSTFS_STARTUP_TOPOLOGY_WAIT_MODE=${cfg.startupTopologyWaitMode}";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStopSec = "120s";
        LimitNOFILE = 65536;
        TasksMax = 4096;
        MemoryHigh = cfg.memoryHigh;
        CPUWeight = cfg.cpuWeight;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = ["-${dataDir}"];
      };
    };
  };
}
