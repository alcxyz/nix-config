# modules/nixos/virtualisation/k3s/default.nix
{
  config,
  pkgs,
  lib,
  hostK8sRole ? null,
  ...
}:
with lib; let
  # Define options specifically for K3s
  cfg = config.k3s; # Using a top-level 'k3s' option for clarity
  roleDefault =
    if hostK8sRole == null
    then "server"
    else hostK8sRole.role;
  roleMaxPods =
    if hostK8sRole == null
    then 110
    else hostK8sRole.maxPods or 110;
  inventoryExtraFlags =
    if hostK8sRole == null
    then []
    else hostK8sRole.extraFlags or [];
in {
  # Define the NixOS options for this module
  options.k3s = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable K3s server setup.";
    };

    role = mkOption {
      type = types.enum ["server" "agent"];
      default = roleDefault;
      description = "The role of this node in the K3s cluster.";
    };

    extraFlags = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra flags to pass to the K3s server/agent binary.";
    };

    maxPods = mkOption {
      type = types.ints.positive;
      default = roleMaxPods;
      description = "Maximum number of Pods the kubelet may schedule on this node.";
    };

    nodeIp = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Stable node address advertised by K3s and used as the Flannel VXLAN endpoint.";
    };

    tlsSans = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Additional Subject Alternative Names for the k3s API server certificate.";
    };

    serverAddr = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Server URL to join for non-bootstrap server/agent nodes.";
    };

    tokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to a file containing the shared k3s server token.";
    };

    clusterInit = mkOption {
      type = types.bool;
      default = false;
      description = "Initialize or migrate the cluster to embedded etcd on this server.";
    };

    rebootWatchdogSec = mkOption {
      type = types.str;
      default = "3min";
      description = ''
        systemd reboot watchdog timeout. Set to "0" on hosts whose firmware
        reset path has not been qualified or is known to wedge during reboot.
      '';
    };
  };

  # Apply configuration if k3s.enable is true
  config = mkIf cfg.enable {
    assertions = optional (hostK8sRole != null) {
      assertion = cfg.role == hostK8sRole.role;
      message = "k3s.role for ${config.networking.hostName} must match inventory k8sRole (${hostK8sRole.role}).";
    };

    # Ensure rpcbind is enabled, often a dependency for Kubernetes components
    services.rpcbind.enable = true;

    # Bound the final reboot phase if firmware or a kernel driver wedges after
    # userspace has shut down. Runtime watchdog policy remains host-specific.
    systemd.settings.Manager.RebootWatchdogSec = cfg.rebootWatchdogSec;

    # A newly installed host may start with a reset RTC.  time-sync.target is
    # only an ordering target and does not itself prove that NTP has corrected
    # the clock.  Starting k3s before that correction can mint an immediately
    # expired local CA, preventing a clean server from joining the cluster.
    systemd.services.k3s-clock-sanity = {
      description = "Wait for a sane synchronized clock before starting k3s";
      wants = [
        "network-online.target"
        "systemd-timesyncd.service"
      ];
      after = [
        "network-online.target"
        "systemd-timesyncd.service"
      ];
      before = ["k3s.service"];
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail
        minimum_epoch=1767225600 # 2026-01-01T00:00:00Z
        for _ in $(${pkgs.coreutils}/bin/seq 1 180); do
          now=$(${pkgs.coreutils}/bin/date +%s)
          if [[ -e /run/systemd/timesync/synchronized && $now -ge $minimum_epoch ]]; then
            exit 0
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done
        echo "clock did not become synchronized and sane before k3s startup" >&2
        exit 1
      '';
    };

    systemd.services.k3s = {
      requires = ["k3s-clock-sanity.service"];
      after = ["k3s-clock-sanity.service"];
    };

    # Configure K3s service
    services.k3s =
      {
        enable = true;
        role = cfg.role;
        extraFlags =
          inventoryExtraFlags
          ++ optional (cfg.nodeIp != null) "--node-ip=${cfg.nodeIp}"
          ++ optional (cfg.maxPods != 110) "--kubelet-arg=max-pods=${toString cfg.maxPods}"
          ++ concatMap (san: ["--tls-san" san]) cfg.tlsSans
          ++ cfg.extraFlags;
      }
      // optionalAttrs (cfg.serverAddr != null) {
        serverAddr = cfg.serverAddr;
      }
      // optionalAttrs (cfg.tokenFile != null) {
        tokenFile = cfg.tokenFile;
      }
      // optionalAttrs cfg.clusterInit {
        clusterInit = true;
      };

    # Configure firewall for K3s
    networking.firewall.allowedTCPPorts = [
      6443 # K3s API Server
      2379 # K3s etcd client port
      2380 # K3s etcd peer port
      7946 # MetalLB speaker memberlist
      10250 # Kubelet metrics endpoint for Metrics Server
    ];
    networking.firewall.allowedUDPPorts = [
      8472 # Flannel VXLAN backend
      7946 # MetalLB speaker memberlist
    ];

    # Pod and service traffic traverses the node over the CNI bridge and
    # flannel overlay. Treat those interfaces as trusted so cross-node
    # cluster traffic is not filtered like regular host ingress.
    networking.firewall.trustedInterfaces = [
      "cni0"
      "flannel.1"
    ];

    # Ensure the k3s package is available in the system environment
    environment.systemPackages = [pkgs.k3s];
  };
}
