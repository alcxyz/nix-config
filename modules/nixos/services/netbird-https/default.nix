{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.netbird-https;
  cleanup = ''
    iptables -w -t raw -D PREROUTING -j nixos-netbird-https 2>/dev/null || true
    iptables -w -t raw -F nixos-netbird-https 2>/dev/null || true
    iptables -w -t raw -X nixos-netbird-https 2>/dev/null || true
  '';
  octet = "([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])";
  word = lib.types.strMatching "[a-zA-Z0-9_.-]+";
in {
  options.services.netbird-https = {
    enable = lib.mkEnableOption "HTTPS on a NetBird address";
    domain = lib.mkOption {type = word;};
    address = lib.mkOption {
      type = lib.types.strMatching "100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.${octet}\\.${octet}";
      description = "Stable IPv4 address assigned to this peer by NetBird.";
    };
    interface = lib.mkOption {
      type = word;
      default = "wt0";
    };
    upstreamPort = lib.mkOption {type = lib.types.port;};
    credentialsFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime file containing lego Cloudflare credentials; never a store path.";
    };
    email = lib.mkOption {type = lib.types.str;};
  };
  config = lib.mkMerge [
    {
      # Stable chain cleanup also runs when disabled. Disable and switch
      # before removing this module's import entirely.
      networking.firewall.extraCommands = lib.mkIf (!cfg.enable && !config.networking.nftables.enable) cleanup;
      networking.firewall.extraStopCommands = lib.mkIf (!cfg.enable && !config.networking.nftables.enable) cleanup;
    }
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = config.networking.firewall.enable;
          message = "NetBird HTTPS requires an enabled firewall.";
        }
        {
          assertion = !config.networking.nftables.enable;
          message = "NetBird HTTPS currently requires the iptables firewall backend.";
        }
        {
          assertion = lib.hasPrefix "/" cfg.credentialsFile && !(lib.hasPrefix "/nix/store/" cfg.credentialsFile);
          message = "NetBird HTTPS credentials must be an absolute runtime path outside the store.";
        }
      ];
      security.acme = {
        acceptTerms = true;
        certs.${cfg.domain} = {
          email = cfg.email;
          group = config.services.nginx.group;
          dnsProvider = "cloudflare";
          environmentFile = cfg.credentialsFile;
          dnsResolver = "1.1.1.1:53";
          reloadServices = ["nginx.service"];
        };
      };
      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;
        virtualHosts.${cfg.domain} = {
          useACMEHost = cfg.domain;
          onlySSL = true;
          listen = [
            {
              addr = cfg.address;
              port = 443;
              ssl = true;
            }
          ];
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString cfg.upstreamPort}";
            proxyWebsockets = true;
            extraConfig = "proxy_read_timeout 3600s;";
          };
        };
      };
      networking.firewall.interfaces.${cfg.interface}.allowedTCPPorts = [443];
      # Reject packets addressed to the VPN listener arriving through other
      # interfaces, including before other filter-table accept rules.
      # Replace only this chain in one raw-table commit. --noflush preserves
      # other chains and flushes declared user chains. The PREROUTING jump
      # remains installed throughout reload; stop must not remove it.
      networking.firewall.extraCommands = ''
        iptables-restore --wait --noflush <<'RULES'
        *raw
        :nixos-netbird-https - [0:0]
        -A nixos-netbird-https -i lo -j RETURN
        -A nixos-netbird-https -d ${cfg.address} ! -i ${cfg.interface} -p tcp --dport 443 -j DROP
        COMMIT
        RULES
        iptables -w -t raw -C PREROUTING -j nixos-netbird-https 2>/dev/null || iptables -w -t raw -I PREROUTING -j nixos-netbird-https
      '';
      systemd.services.nginx = {
        after = ["netbird.service"];
        wants = ["netbird.service"];
        # NetBird may assign its address after nginx starts. Retry the bind;
        # never fall back to a wildcard listener.
        startLimitIntervalSec = lib.mkForce 0;
        serviceConfig.Restart = lib.mkForce "on-failure";
      };
    })
  ];
}
