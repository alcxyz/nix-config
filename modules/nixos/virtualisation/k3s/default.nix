# modules/nixos/virtualisation/k3s/default.nix
{ config, pkgs, lib, ... }:

with lib;

let
  # Define options specifically for K3s
  cfg = config.k3s; # Using a top-level 'k3s' option for clarity
in
{
  # Define the NixOS options for this module
  options.k3s = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable K3s server setup.";
    };

    role = mkOption {
      type = types.enum [ "server" "agent" ];
      default = "server";
      description = "The role of this node in the K3s cluster.";
    };

    extraFlags = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra flags to pass to the K3s server/agent binary.";
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
  };

  # Apply configuration if k3s.enable is true
  config = mkIf cfg.enable {
    # Ensure rpcbind is enabled, often a dependency for Kubernetes components
    services.rpcbind.enable = true;

    # Configure K3s service
    services.k3s =
      {
        enable = true;
        role = cfg.role;
        extraFlags = cfg.extraFlags;
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
    ];
    networking.firewall.allowedUDPPorts = [
      8472 # Flannel VXLAN backend
    ];

    # Pod and service traffic traverses the node over the CNI bridge and
    # flannel overlay. Treat those interfaces as trusted so cross-node
    # cluster traffic is not filtered like regular host ingress.
    networking.firewall.trustedInterfaces = [
      "cni0"
      "flannel.1"
    ];

    # Ensure the k3s package is available in the system environment
    environment.systemPackages = [ pkgs.k3s ];
  };
}
