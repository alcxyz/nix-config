# modules/nixos/services/k8s-api-vip/default.nix
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.k8s-api-vip;
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
      default = "192.168.1.250";
      description = "Floating LAN IP address for Kubernetes API clients.";
    };

    prefixLength = mkOption {
      type = types.ints.between 1 32;
      default = 24;
      description = "CIDR prefix length for the floating VIP.";
    };

    virtualRouterId = mkOption {
      type = types.ints.between 1 255;
      default = 43;
      description = "VRRP router ID for the Kubernetes API VIP.";
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
        script = "${pkgs.netcat-openbsd}/bin/nc -z -w 1 127.0.0.1 6443";
        interval = 2;
        timeout = 1;
        fall = 2;
        rise = 2;
        # A zero-weight track script puts the instance into FAULT when the
        # local API listener fails. A negative weight only lowers election
        # priority; with nopreempt, backups will not take the VIP from an
        # unhealthy master.
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
        virtualIps = [
          {
            addr = "${cfg.vip}/${toString cfg.prefixLength}";
            dev = cfg.interface;
          }
        ];
        trackScripts = ["k3s_api"];
        extraConfig = ''
          advert_int 1
          garp_master_delay 1
          garp_master_repeat 3
        '';
      };
    };
  };
}
