# modules/nixos/services/k8s-api-vip/default.nix
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.k8s-api-vip;
  # K3s generates the non-admin kube-proxy identity in its local agent state.
  # Prefer anonymous readiness, and use only that existing identity on denial.
  readyProbe = pkgs.writeShellScript "k3s-api-ready" ''
    request() {
      ${pkgs.curl}/bin/curl -q --silent --show-error \
        --noproxy '*' --proto '=https' --connect-timeout 1 --max-time 2 \
        --cacert ${escapeShellArg cfg.readinessCaFile} \
        --output /dev/null --write-out '%{http_code}' "$@" \
        https://127.0.0.1:6443/readyz
    }
    status="$(request)" || exit 1
    case "$status" in
      200) exit 0 ;;
      401|403) ;;
      *) exit 1 ;;
    esac
    ${
      if cfg.readinessClient == null
      then ''
        echo "Anonymous API readiness denied; no local readiness client configured" >&2
        exit 1
      ''
      else ''
        status="$(request \
          --cert ${escapeShellArg cfg.readinessClient.certificateFile} \
          --key ${escapeShellArg cfg.readinessClient.keyFile})" || exit 1
        test "$status" = 200
      ''
    }
  '';
in {
  options.services.k8s-api-vip = {
    enable = mkEnableOption "a floating LAN VIP for the k3s API server";

    interface = mkOption {
      type = types.str;
      description = "LAN interface that should carry the Kubernetes API VIP.";
    };

    sourceIp = mkOption {
      type = types.str;
      description = "This node's LAN IP address used for unicast VRRP.";
    };

    peers = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Other keepalived peer LAN IPs for unicast VRRP.";
    };

    vip = mkOption {
      type = types.str;
      description = "Floating LAN IP address for Kubernetes API clients.";
    };

    prefixLength = mkOption {
      type = types.ints.between 1 32;
      description = "CIDR prefix length for the floating VIP.";
    };

    virtualRouterId = mkOption {
      type = types.ints.between 1 255;
      description = "VRRP router ID for the Kubernetes API VIP.";
    };

    readinessCaFile = mkOption {
      type = types.str;
      default = "/var/lib/rancher/k3s/agent/server-ca.crt";
      description = "Existing local API server CA file, verified for every readiness request.";
    };

    readinessClient = mkOption {
      type = types.nullOr (types.submodule {
        options = genAttrs ["certificateFile" "keyFile"] (name:
          mkOption {
            type = types.str;
            description = "Existing local readiness TLS ${name}; contents stay outside the Nix store.";
          });
      });
      # These are upstream K3s-generated paths, not newly provisioned secrets.
      default = {
        certificateFile = "/var/lib/rancher/k3s/agent/client-kube-proxy.crt";
        keyFile = "/var/lib/rancher/k3s/agent/client-kube-proxy.key";
      };
      description = ''
        Least privileged existing local client for /readyz when anonymous access
        returns 401 or 403. Defaults to K3s's non-admin kube-proxy identity.
        Override for a nonstandard data directory; null requires anonymous
        readiness. Never supply file contents or administrator credentials.
      '';
    };

    priority = mkOption {
      type = types.ints.between 1 255;
      default = 100;
      description = "VRRP election priority for this node.";
    };
  };

  config = mkIf cfg.enable {
    services.keepalived = {
      enable = true;
      openFirewall = true;
      enableScriptSecurity = true;

      vrrpScripts.k3s_api = {
        script = toString readyProbe;
        interval = 2;
        timeout = 5;
        fall = 2;
        rise = 2;
        # Start ineligible, then require two successes before joining election.
        extraConfig = "init_fail";
        # FAULT removes this instance from election, rather than just lowering
        # its priority. When all APIs are unready, no instance holds the VIP.
        weight = 0;
        user = "root";
      };

      vrrpInstances.k8s_api = {
        interface = cfg.interface;
        state = "BACKUP";
        virtualRouterId = cfg.virtualRouterId;
        priority = cfg.priority;
        noPreempt = true;
        unicastSrcIp = cfg.sourceIp;
        unicastPeers = cfg.peers;
        # Keep the floating address out of connected-route source selection.
        # Without noprefixroute, a VIP added before the DHCP address can become
        # the preferred source for unrelated LAN traffic from the current
        # holder.
        virtualIps = [];
        trackScripts = ["k3s_api"];
        extraConfig = ''
          virtual_ipaddress {
            ${cfg.vip}/${toString cfg.prefixLength} dev ${cfg.interface} noprefixroute
          }
          advert_int 1
          garp_master_delay 1
          garp_master_repeat 3
        '';
      };
    };

    # Flannel chooses its VXLAN source address when k3s starts. Keep the
    # floating API address off this node until that selection is complete,
    # then allow keepalived to participate in the VIP election again.
    systemd.services.keepalived = {
      after = ["k3s.service"];
      partOf = ["k3s.service"];
    };
    systemd.services.k3s.wants = ["keepalived.service"];
  };
}
