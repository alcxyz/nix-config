{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.pihole-native;

  piholeStart = pkgs.writeShellScript "pihole-ftl-start" ''
    set -euo pipefail

    export FTLCONF_dns_interface="${cfg.listenInterface}"
    export FTLCONF_dns_listeningMode="BIND"
    export FTLCONF_dns_upstreams="${cfg.upstream}"
    export FTLCONF_misc_readOnly="false"
    export FTLCONF_webserver_domain="${cfg.hostName}"
    export FTLCONF_webserver_port="${toString cfg.webPort}o"
    export FTLCONF_webserver_paths_webroot="${pkgs.pihole-web}/share/"
    export FTLCONF_webserver_paths_webhome="/"
    export FTLCONF_files_database="${cfg.stateDirectory}/pihole-FTL.db"
    export FTLCONF_files_gravity="${cfg.stateDirectory}/gravity.db"
    export FTLCONF_files_log_ftl="${cfg.logDirectory}/FTL.log"
    export FTLCONF_files_log_dnsmasq="${cfg.logDirectory}/pihole.log"
    export FTLCONF_files_log_webserver="${cfg.logDirectory}/webserver.log"
    export FTLCONF_webserver_tls_cert="${cfg.stateDirectory}/tls.pem"

    if [[ -s "${cfg.passwordFile}" ]]; then
      export FTLCONF_webserver_api_password="$(<"${cfg.passwordFile}")"
    fi

    exec ${lib.getExe pkgs.pihole-ftl} no-daemon
  '';
in {
  imports = [
    (lib.mkRenamedOptionModule ["services" "alc-pihole-native"] ["services" "pihole-native"])
  ];

  options.services.pihole-native = {
    enable = lib.mkEnableOption "native Pi-hole FTL service";

    listenInterface = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Host interface Pi-hole should bind for DNS.";
    };

    hostName = lib.mkOption {
      type = lib.types.str;
      default = "pi.hole";
      description = "Pi-hole web/API hostname.";
    };

    webPort = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = "Host port for the Pi-hole web/API server.";
    };

    upstream = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1#5335";
      description = "Pi-hole upstream resolver.";
    };

    stateDirectory = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/pihole/etc";
      description = "Mutable Pi-hole v6 state directory, exposed at /etc/pihole.";
    };

    logDirectory = lib.mkOption {
      type = lib.types.path;
      default = "/var/log/pihole";
      description = "Pi-hole log directory.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.path;
      description = "Runtime file containing the Pi-hole API/admin password.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.pihole = {};
    users.users.pihole = {
      isSystemUser = true;
      group = "pihole";
      home = "/var/lib/pihole";
    };

    environment.systemPackages = [
      pkgs.pihole
      pkgs.pihole-ftl
    ];

    systemd.tmpfiles.rules = [
      "d /var/lib/pihole 0755 root root - -"
      "d ${cfg.stateDirectory} 0700 pihole pihole - -"
      "Z ${cfg.stateDirectory} 0700 pihole pihole - -"
      "L+ /etc/pihole - - - - ${cfg.stateDirectory}"
      "d ${cfg.logDirectory} 0700 pihole pihole - -"
    ];

    systemd.services.pihole-ftl = {
      description = "Pi-hole FTL";
      after = [
        "network-online.target"
        "sops-nix.service"
        "time-sync.target"
        "unbound.service"
      ];
      wants = [
        "network-online.target"
        "sops-nix.service"
        "time-sync.target"
      ];
      requires = [
        "unbound.service"
      ];
      wantedBy = ["multi-user.target"];
      path = [
        pkgs.pihole
        pkgs.pihole-ftl
      ];
      serviceConfig = {
        Type = "simple";
        User = "pihole";
        Group = "pihole";
        ExecStart = piholeStart;
        Restart = "on-failure";
        RestartSec = 1;
        AmbientCapabilities = [
          "CAP_NET_BIND_SERVICE"
          "CAP_NET_RAW"
          "CAP_NET_ADMIN"
          "CAP_SYS_NICE"
          "CAP_IPC_LOCK"
          "CAP_CHOWN"
          "CAP_SYS_TIME"
        ];
        CapabilityBoundingSet = [
          "CAP_NET_BIND_SERVICE"
          "CAP_NET_RAW"
          "CAP_NET_ADMIN"
          "CAP_SYS_NICE"
          "CAP_IPC_LOCK"
          "CAP_CHOWN"
          "CAP_SYS_TIME"
        ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        DevicePolicy = "closed";
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ProtectControlGroups = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ReadWritePaths = [
          "/etc/pihole"
          cfg.stateDirectory
          cfg.logDirectory
        ];
        RestrictAddressFamilies = "AF_UNIX AF_INET AF_INET6 AF_NETLINK";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        MemoryDenyWriteExecute = true;
        LockPersonality = true;
      };
    };

    networking.firewall.allowedTCPPorts = [
      53
      cfg.webPort
    ];
    networking.firewall.allowedUDPPorts = [53];
  };
}
