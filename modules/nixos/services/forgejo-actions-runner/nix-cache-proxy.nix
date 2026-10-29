# Pull-through cache of the upstream Nix binary caches for the rootless Podman
# runner pool (ADR-0103). One nginx process is the cache and its only
# listener: it answers GET and HEAD of what a substituter reads and has no
# write endpoint, and every path it serves keeps the upstream signatures the
# job verifies itself.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.forgejo-actions-runner;
  proxy = cfg.nixCacheProxy;
  enabled = cfg.enable && cfg.podmanCanary.enable && proxy.enable;
  firewall = config.networking.firewall;
  # Without IPv6 there is no ip6tables to call and no [::] to listen on.
  ipv6 = config.networking.enableIPv6;
  user = "forgejo-nix-cache";
  runtime = "/run/forgejo-nix-cache";
  # An upstream is a bare `https://host[/path]`: no port, query or fragment,
  # so its host names a prefix and its path goes straight into a rewrite.
  bareUpstream = "https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*[A-Za-z0-9._~-])?";
  # The host's HTTPS substituters, once each and without store parameters:
  # NixOS's default `https://cache.nixos.org/`, an explicit one without the
  # slash and one with `?priority=` are the same cache. Others, such as one
  # with a port, are left out.
  httpsCaches = urls:
    lib.unique (builtins.filter (url: builtins.match bareUpstream url != null)
      (map (url: lib.removeSuffix "/" (builtins.head (lib.splitString "?" url)))
        (builtins.filter (lib.hasPrefix "https://") urls)));
  hostOf = url: builtins.head (lib.splitString "/" (lib.removePrefix "https://" url));
  # Each upstream is served under its own prefix, named after its host.
  prefixes = map hostOf proxy.upstreams;
  narPaths = "(nix-cache-info|[0-9a-z]{32}\\.narinfo|nar/[0-9A-Za-z-]+\\.nar(\\.[0-9a-z]+)?)";
  upstreamLocation = url: let
    host = hostOf url;
    path = lib.removePrefix "https://${host}" url;
    prefix = lib.escapeRegex host;
  in ''
    location ~ "^/${prefix}/${narPaths}$" {
      limit_except GET {
        deny all;
      }
      # A variable makes nginx resolve the host per request through the
      # resolver, following its DNS TTL, and lets nginx start without DNS.
      # SNI and verification use the literal name. `set` must precede the
      # rewrite, whose `break` ends the rewrite directives.
      set $nix_upstream ${host};
      # Swap the prefix for the upstream's path and drop any query, so one
      # object has one cache entry.
      rewrite "^/${prefix}(/.*)$" ${path}$1? break;
      proxy_pass https://$nix_upstream$uri;
      proxy_cache_key ${host}$uri;
      proxy_ssl_name ${host};
    }
  '';
  # nginx's resolver needs addresses, and the hosts take theirs from
  # NetworkManager or NetBird at run time, so the unit writes them from
  # /etc/resolv.conf when it starts or reloads. Without any, it names the
  # systemd-resolved stub address, and lookups fail until a reload.
  writeResolver = pkgs.writeShellScript "forgejo-nix-cache-resolver" ''
    set -eu
    servers=$(${pkgs.gawk}/bin/awk '
      $1 == "nameserver" && $2 !~ /%/ {
        address = $2
        if (address ~ /:/) address = "[" address "]"
        printf "%s ", address
      }' /etc/resolv.conf 2>/dev/null || true)
    [ -n "$servers" ] || servers="127.0.0.53"
    printf 'resolver %s ipv6=off;\nresolver_timeout 5s;\n' "$servers" > ${runtime}/resolver.conf.new
    ${pkgs.coreutils}/bin/mv ${runtime}/resolver.conf.new ${runtime}/resolver.conf
  '';
  nginxConfig = pkgs.writeText "forgejo-nix-cache.conf" ''
    worker_processes 1;
    pid ${runtime}/nginx.pid;
    error_log stderr warn;
    events {
      worker_connections 512;
    }
    http {
      access_log off;
      client_body_temp_path ${runtime}/client_body;
      proxy_temp_path ${runtime}/proxy;
      fastcgi_temp_path ${runtime}/fastcgi;
      uwsgi_temp_path ${runtime}/uwsgi;
      scgi_temp_path ${runtime}/scgi;
      client_max_body_size 1k;

      include ${runtime}/resolver.conf;

      # The cache manager evicts least recently used entries to bring the
      # cache back under max_size; it is a soft bound, checked periodically.
      proxy_cache_path ${proxy.storagePath} levels=1:2 keys_zone=forgejo_nix_cache:32m max_size=${proxy.maxSize} inactive=${proxy.inactive} use_temp_path=off;
      proxy_cache forgejo_nix_cache;
      # Store paths are content-addressed, so a hit stays valid; a miss is
      # cached briefly and nothing else at all, whatever upstream headers say.
      proxy_ignore_headers Cache-Control Expires X-Accel-Expires Set-Cookie Vary;
      proxy_cache_valid 200 ${proxy.inactive};
      proxy_cache_valid 404 1m;
      # Concurrent jobs share one upstream fetch per object.
      proxy_cache_lock on;
      proxy_cache_lock_timeout 10m;
      proxy_cache_lock_age 10m;
      proxy_http_version 1.1;
      proxy_read_timeout 300s;
      proxy_set_header Accept-Encoding "";
      proxy_set_header Authorization "";
      proxy_set_header Cookie "";
      proxy_ssl_server_name on;
      proxy_ssl_verify on;
      proxy_ssl_verify_depth 4;
      proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;

      server {
        listen 0.0.0.0:${toString proxy.port};
        ${lib.optionalString ipv6 "listen [::]:${toString proxy.port};"}
        ${lib.concatMapStrings upstreamLocation proxy.upstreams}
        location / {
          return 404;
        }
      }
    }
  '';
in {
  options.services.forgejo-actions-runner.nixCacheProxy = {
    enable = lib.mkEnableOption ''
      a read-only pull-through cache of the upstream Nix binary caches for the
      Podman runner pool. Its jobs get it as an extra substituter through the
      runner environment; the job containers reach it through Podman's
      `host.containers.internal`, and a raw-table rule drops traffic to the
      port from every source that is not one of this host's addresses. Local
      processes, host-network containers and pods included, still reach the
      read-only listener'';
    port = lib.mkOption {
      type = lib.types.port;
      default = 8501;
      description = "TCP port the cache listens on, on all of the host's addresses.";
    };
    storagePath = lib.mkOption {
      type = lib.types.strMatching "/.+";
      default = "/var/lib/forgejo-nix-cache";
      description = ''
        Directory of the cached responses. Point it at the host's CI disk
        where one exists, for example by mounting a dataset here; the cache
        waits for that mount.
      '';
    };
    maxSize = lib.mkOption {
      type = lib.types.strMatching "[1-9][0-9]*[kKmMgG]";
      default = "10G";
      description = ''
        Soft bound of the cache: nginx's cache manager evicts the least
        recently used entries when it finds the cache above it, and counts
        files only once complete. A quota or a dedicated filesystem for
        `storagePath` is the hard bound.
      '';
    };
    inactive = lib.mkOption {
      type = lib.types.strMatching "[1-9][0-9]*[smhd]";
      default = "30d";
      description = "How long an entry nobody reads stays cached.";
    };
    upstreams = lib.mkOption {
      type = lib.types.nonEmptyListOf (lib.types.strMatching bareUpstream);
      default = httpsCaches config.nix.settings.substituters;
      defaultText = lib.literalExpression "the HTTPS entries of config.nix.settings.substituters, without store parameters, trailing slashes, ports and duplicates";
      description = ''
        Upstream binary caches as bare `https://host[/path]` URLs (no port,
        query or fragment), fetched over HTTPS with the host's CA bundle.
        Each is served under a prefix named after its host, and jobs get one
        substituter per upstream, in this order.
      '';
    };
    jobNixConfig = lib.mkOption {
      type = lib.types.lines;
      readOnly = true;
      internal = true;
      default = ''
        extra-substituters = ${lib.concatImapStringsSep " " (i: prefix: "http://host.containers.internal:${toString proxy.port}/${prefix}?priority=${toString (9 + i)}") prefixes}
        fallback = true
        connect-timeout = 5
      '';
      description = ''
        `NIX_CONFIG` the Podman runners give their jobs. Priorities 10 and up
        put the cache before the upstreams (cache.nixos.org has 40).
        `fallback` lets Nix skip an unreachable substituter instead of
        failing, so an outage of the cache only costs speed.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.enable && proxy.enable) {
      assertions = [
        {
          assertion = cfg.podmanCanary.enable;
          message = "The CI Nix cache proxy serves the Podman runner pool and requires podmanCanary.enable.";
        }
      ];
    })
    (lib.mkIf enabled {
      assertions = [
        {
          # The guard below runs from the NixOS iptables firewall's hooks,
          # which neither the nftables nor the firewalld backend runs; without
          # them the port would be open to the LAN and trusted interfaces.
          assertion = firewall.enable && firewall.backend == "iptables";
          message = "The CI Nix cache proxy requires the iptables NixOS firewall, which installs the rule refusing its port to other hosts.";
        }
        {
          assertion = !(cfg.podmanCanary.jobEnv ? NIX_CONFIG);
          message = "podmanCanary.jobEnv must not set NIX_CONFIG while the CI Nix cache proxy supplies it.";
        }
        {
          assertion = lib.allUnique prefixes;
          message = "The CI Nix cache proxy needs upstreams on distinct hosts.";
        }
      ];

      users.users.${user} = {
        isSystemUser = true;
        group = user;
      };
      users.groups.${user} = {};
      systemd.tmpfiles.rules = ["d ${proxy.storagePath} 0700 ${user} ${user} -"];

      systemd.services.forgejo-nix-cache = {
        description = "Read-only pull-through cache of the upstream Nix caches for CI jobs";
        wantedBy = ["multi-user.target"];
        # nginx resolves upstreams per request, so it starts without DNS.
        after = ["network.target"];
        unitConfig.RequiresMountsFor = [proxy.storagePath];
        serviceConfig = {
          ExecStartPre = writeResolver;
          ExecStart = "${pkgs.nginx}/bin/nginx -e stderr -c ${nginxConfig} -g 'daemon off;'";
          ExecReload = [
            writeResolver
            "${pkgs.coreutils}/bin/kill -HUP $MAINPID"
          ];
          Restart = "on-failure";
          RestartSec = "10s";
          User = user;
          Group = user;
          RuntimeDirectory = "forgejo-nix-cache";
          RuntimeDirectoryMode = "0700";
          ReadWritePaths = [proxy.storagePath];
          UMask = "0077";
          CapabilityBoundingSet = "";
          NoNewPrivileges = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = "AF_UNIX AF_INET AF_INET6";
          RestrictNamespaces = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          SystemCallArchitectures = "native";
        };
      };

      # Pick up the host's resolvers when NetworkManager or NetBird changes
      # them.
      systemd.paths.forgejo-nix-cache-resolver = {
        wantedBy = ["multi-user.target"];
        pathConfig.PathChanged = "/etc/resolv.conf";
      };
      systemd.services.forgejo-nix-cache-resolver = {
        description = "Reload the CI Nix cache's resolvers";
        serviceConfig.Type = "oneshot";
        script = "${pkgs.systemd}/bin/systemctl try-reload-or-restart forgejo-nix-cache.service";
      };

      # pasta opens the job's connection from the host itself, with the
      # host's own address as its source. For traffic addressed to the host,
      # drop every other source in the raw table's PREROUTING, before any
      # INPUT chain (the NixOS firewall's trusted interfaces, kube-router's or
      # NetBird's accept rules) sees the packet. The firewall's start and reload hooks rebuild the chain
      # idempotently; a firewall stop leaves it in place.
      networking.firewall.extraCommands = let
        guard = command: ''
          ${command} -w -t raw -N forgejo-nix-cache 2>/dev/null || true
          ${command} -w -t raw -F forgejo-nix-cache
          ${command} -w -t raw -A forgejo-nix-cache -p tcp --dport ${toString proxy.port} -m addrtype --dst-type LOCAL ! --src-type LOCAL -j DROP
          ${command} -w -t raw -C PREROUTING -j forgejo-nix-cache 2>/dev/null \
            || ${command} -w -t raw -I PREROUTING -j forgejo-nix-cache
        '';
      in
        guard "iptables" + lib.optionalString ipv6 (guard "ip6tables");
    })
  ];
}
