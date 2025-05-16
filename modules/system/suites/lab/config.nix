{ options, config, lib, pkgs, ... }:
with lib;
{
  options.lab = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the lab system configuration (services, virtualization, firewall).";
    };
  };

  config = mkIf config.lab.enable {
    services.k3s = {
      enable = true;
      role = "server";
      extraFlags = toString [
      #"--flannel-backend=none"
      # If br0 has a static IP you wish to use for the K3s server, uncomment and adjust the following line
      # "--node-ip 192.168.1.100"
      # "--kubelet-arg=v=4" # Optionally add additional args to k3s
      ];
    };

    services.rpcbind.enable = true;

    virtualisation.containers.enable = true;
    virtualisation = {
        podman = {
          enable = true;
          #dockerCompat = true;
          defaultNetwork.settings.dns_enabled = true;
        };
      };

    virtualisation.docker.enable = true;
    virtualisation.docker.rootless = {
        enable = true;
        setSocketVariable = true;
    };

    networking.firewall.allowedTCPPorts = [
      6443 # k3s: required so that pods can reach the API server (running on port 6443 by default)
      # 2379 # k3s, etcd clients: required if using a "High Availability Embedded etcd" configuration
      # 2380 # k3s, etcd peers: required if using a "High Availability Embedded etcd" configuration
    ];
    networking.firewall.allowedUDPPorts = [
      # 8472 # k3s, flannel: required if using multi-node for inter-node networking
    ];
  };
}
