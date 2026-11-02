{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.pihole-native;

  waitForListenInterface = pkgs.writeShellScript "pihole-wait-for-listen-interface" ''
    set -euo pipefail

    interface=${lib.escapeShellArg cfg.listenInterface}

    for _ in $(${pkgs.coreutils}/bin/seq 1 120); do
      if ${pkgs.iproute2}/bin/ip link show dev "$interface" >/dev/null 2>&1 \
        && ${pkgs.iproute2}/bin/ip -o -4 address show dev "$interface" scope global \
          | ${pkgs.gnugrep}/bin/grep -q ' inet '; then
        exit 0
      fi

      ${pkgs.coreutils}/bin/sleep 1
    done

    echo "Pi-hole listen interface $interface did not acquire a global IPv4 address" >&2
    exit 1
  '';

  gravityDatabase = "${cfg.stateDirectory}/gravity.db";
  blocklistStamp = "${cfg.stateDirectory}/nixos-blocklists.stamp";

  sqlString = value: "'" + lib.replaceStrings ["'"] ["''"] value + "'";

  # Additive only: INSERT OR IGNORE keeps every row already in the adlist
  # table, including lists added in the web interface, and never changes the
  # enabled state or comment of a list that is already present.
  blocklistSql = pkgs.writeText "pihole-blocklists.sql" (''
      .timeout 30000
      BEGIN;
    ''
    + lib.concatMapStrings (list: ''
      INSERT OR IGNORE INTO adlist (address, enabled, comment, type) VALUES (${sqlString list.url}, ${
        if list.enabled
        then "1"
        else "0"
      }, ${
        if list.comment == null
        then "NULL"
        else sqlString list.comment
      }, 0);
    '')
    cfg.blocklists
    + ''
      COMMIT;
    '');

  # Counts enabled declared lists that the last gravity run did not load:
  # gravity.sh records status 1 (updated), 2 (unchanged) or 3 (unavailable,
  # cached copy used) for a list it loaded, and 4 when it has nothing.
  blocklistPendingSql = pkgs.writeText "pihole-blocklists-pending.sql" ''
    .timeout 30000
    SELECT COUNT(*) FROM adlist WHERE type = 0 AND enabled = 1
      AND address IN (${lib.concatMapStringsSep ", " (list: sqlString list.url) cfg.blocklists})
      AND (status IS NULL OR status NOT IN (1, 2, 3));
  '';

  # Runs as the pihole user. gravity.sh resolves the database through
  # `pihole-FTL --config`, which reads /etc/pihole/pihole.toml rather than the
  # FTLCONF_ variables of the FTL unit; /etc/pihole links to stateDirectory, so
  # both name the same gravity.db.
  gravityUpdate = pkgs.writeShellScript "pihole-gravity-update" ''
    set -euo pipefail

    exec 9>${lib.escapeShellArg "${cfg.stateDirectory}/nixos-gravity.lock"}
    flock 9

    if [[ ! -e ${lib.escapeShellArg gravityDatabase} ]]; then
      # gravity.sh creates and migrates the database on its first run.
      pihole -g
    fi

    ${lib.optionalString (cfg.blocklists != []) ''
      pihole-FTL sqlite3 -ni ${lib.escapeShellArg gravityDatabase} < ${blocklistSql}
    ''}

    pihole -g

    failed=0
    ${lib.optionalString (cfg.blocklists != []) ''
      # Record the declared set as loaded only when every enabled declared
      # list was loaded, so a failed download is retried at the next boot or
      # switch instead of being treated as done.
      pending="$(pihole-FTL sqlite3 -ni ${lib.escapeShellArg gravityDatabase} < ${blocklistPendingSql})"
      if [[ "$pending" == 0 ]]; then
        printf '%s\n' ${blocklistSql} > ${lib.escapeShellArg blocklistStamp}
      else
        echo "pihole-gravity: $pending declared blocklist(s) could not be loaded" >&2
        rm -f ${lib.escapeShellArg blocklistStamp}
        failed=1
      fi
    ''}

    # Ask FTL to reload the new gravity database, as `pihole reloadlists`
    # does; FTL has no PID file under this module's sandbox.
    pid="$(systemctl show --property MainPID --value pihole-ftl.service)"
    if [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]]; then
      signal="$(pihole-FTL sigrtmin 2>/dev/null || true)"
      [[ "$signal" =~ ^[0-9]+$ ]] || signal=RTMIN
      kill "-$signal" "$pid"
    fi

    exit "$failed"
  '';

  # Runs as root because it starts a unit. Queues a gravity update when the
  # declared lists differ from the ones the last successful update loaded.
  blocklistTrigger = pkgs.writeShellScript "pihole-blocklists-trigger" ''
    set -euo pipefail

    if [[ "$(cat ${lib.escapeShellArg blocklistStamp} 2>/dev/null || true)" != ${lib.escapeShellArg "${blocklistSql}"} ]]; then
      systemctl start --no-block pihole-gravity.service
    fi
  '';

  blocklistOptions = {
    options = {
      url = lib.mkOption {
        type = lib.types.str;
        description = "Address of the blocklist.";
      };

      comment = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Comment shown for the list in the Pi-hole web interface.";
      };

      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Enabled state for the list when it is first added. A list that is
          already in gravity keeps its current state, so disable it in the web
          interface. Deleting a list that is still declared does not last: the
          next gravity update adds it again.
        '';
      };
    };
  };

  piholeStart = pkgs.writeShellScript "pihole-ftl-start" ''
    set -euo pipefail

    export FTLCONF_dns_interface="${cfg.listenInterface}"
    export FTLCONF_dns_listeningMode="BIND"
    export FTLCONF_dns_upstreams="${cfg.upstream}"
    export FTLCONF_dns_rateLimit_count="${toString cfg.rateLimitCount}"
    export FTLCONF_dns_rateLimit_interval="${toString cfg.rateLimitInterval}"
    export FTLCONF_misc_dnsmasq_lines=${lib.escapeShellArg (lib.concatMapStringsSep ";" (domain: "local=/${domain}/") cfg.localDomains)}
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
    ${lib.optionalString (cfg.webAcl != "") ''
      export FTLCONF_webserver_acl="${cfg.webAcl}"
    ''}

    ${
      if cfg.disableWebPassword
      then ''
        export FTLCONF_webserver_api_password=""
      ''
      else
        lib.optionalString (cfg.passwordFile != null) ''
          if [[ -s "${cfg.passwordFile}" ]]; then
            export FTLCONF_webserver_api_password="$(<"${cfg.passwordFile}")"
          fi
        ''
    }

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

    localDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "DNS domains Pi-hole answers locally without forwarding other record types upstream.";
    };

    rateLimitCount = lib.mkOption {
      type = lib.types.addCheck lib.types.int (value: value >= 0);
      default = 1000;
      description = "Maximum Pi-hole DNS queries allowed per client during rateLimitInterval. Set to 0 with rateLimitInterval = 0 to disable rate limiting.";
    };

    rateLimitInterval = lib.mkOption {
      type = lib.types.addCheck lib.types.int (value: value >= 0);
      default = 60;
      description = "Pi-hole DNS rate-limit interval in seconds. Set to 0 with rateLimitCount = 0 to disable rate limiting.";
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
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Runtime file containing the Pi-hole API/admin password.";
    };

    disableWebPassword = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Set an explicitly empty Pi-hole web/API password.";
    };

    blocklists = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule blocklistOptions);
      default = [];
      description = ''
        Blocklists added to gravity when missing. Seeding is additive: lists
        already in gravity, including ones added in the web interface, are
        kept unchanged, and removing an entry here does not remove the list.
        To retire a declared list, remove it here and then delete or disable
        it in the web interface. A change to this set queues a gravity update.
      '';
    };

    gravityUpdate = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to refresh gravity from its lists on a timer.";
      };

      onCalendar = lib.mkOption {
        type = lib.types.str;
        default = "weekly";
        description = "systemd OnCalendar expression for the gravity update.";
      };
    };

    webAcl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Pi-hole webserver ACL. Empty means Pi-hole allows all sources.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.listenInterface != "";
        message = "services.pihole-native.listenInterface must be set when Pi-hole is enabled.";
      }
      {
        assertion =
          (cfg.rateLimitCount == 0 && cfg.rateLimitInterval == 0)
          || (cfg.rateLimitCount > 0 && cfg.rateLimitInterval > 0);
        message = "services.pihole-native rateLimitCount and rateLimitInterval must either both be 0 or both be positive.";
      }
      {
        assertion = lib.all (domain: domain != "" && !(lib.hasInfix "/" domain) && !(lib.hasInfix ";" domain) && !(lib.hasInfix "\n" domain)) cfg.localDomains;
        message = "services.pihole-native.localDomains entries must be non-empty DNS names without '/', ';', or newlines.";
      }
      {
        assertion = lib.all (list: list.url != "" && !(lib.hasInfix "\n" list.url) && (list.comment == null || !(lib.hasInfix "\n" list.comment))) cfg.blocklists;
        message = "services.pihole-native.blocklists entries need a non-empty url, and url and comment must not contain newlines.";
      }
    ];

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

    services.logrotate.settings.pihole-native = {
      files = [
        "${cfg.logDirectory}/FTL.log"
        "${cfg.logDirectory}/pihole.log"
        "${cfg.logDirectory}/webserver.log"
      ];
      frequency = "daily";
      rotate = 14;
      maxsize = "100M";
      compress = true;
      delaycompress = true;
      copytruncate = true;
      missingok = true;
      notifempty = true;
      su = "pihole pihole";
      create = "0640 pihole pihole";
    };

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
        ExecStartPre = [
          waitForListenInterface
          "+${pkgs.coreutils}/bin/chown -R pihole:pihole ${cfg.stateDirectory} ${cfg.logDirectory}"
        ];
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

    systemd.services.pihole-gravity = {
      description = "Update Pi-hole gravity from its lists";
      after = [
        "network-online.target"
        "pihole-ftl.service"
      ];
      wants = ["network-online.target"];
      path = [
        pkgs.pihole
        pkgs.pihole-ftl
        pkgs.systemd
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "pihole";
        Group = "pihole";
        ExecStart = gravityUpdate;
        TimeoutStartSec = "30min";
        Nice = 10;
        IOSchedulingClass = "idle";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ProtectControlGroups = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ReadWritePaths = [
          "/etc/pihole"
          cfg.stateDirectory
        ];
        RestrictAddressFamilies = "AF_UNIX AF_INET AF_INET6 AF_NETLINK";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };

    systemd.timers.pihole-gravity = lib.mkIf cfg.gravityUpdate.enable {
      description = "Update Pi-hole gravity from its lists";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.gravityUpdate.onCalendar;
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    # Restarted on switch when the declared lists change, since its script
    # names them; a failed or interrupted update is retried at the next boot.
    systemd.services.pihole-blocklists = lib.mkIf (cfg.blocklists != []) {
      description = "Queue a Pi-hole gravity update when declared lists change";
      after = ["pihole-ftl.service"];
      wantedBy = [
        "multi-user.target"
        "pihole-ftl.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = blocklistTrigger;
      };
    };

    networking.firewall.allowedTCPPorts = [
      53
      cfg.webPort
    ];
    networking.firewall.allowedUDPPorts = [53];
  };
}
