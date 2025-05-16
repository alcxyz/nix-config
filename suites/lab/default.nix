{ options
, config
, lib
, pkgs
, ...
}:
with lib;
with lib.custom; let
  cfg = config.suites.lab;
in
{
  options.suites.lab = with types; {
    enable = mkBoolOpt false "Enable the lab suite";
  };

  config = mkIf cfg.enable {

    environment.systemPackages = with pkgs; [
      terraform
      opentofu
      ansible
      k3s
      kubectl
      kubernetes-helm
      kubeswitch
      k9s
      lens
      termshark
      atac
      azure-cli
      google-cloud-sdk
      devbox
      cockpit
      podman-compose
      lima
    ];

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

    #boot.supportedFilesystems = [ "nfs" ];
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

    #environment.variables.KUBECONFIG = "$HOME/.kube/config:$HOME/.kube/rpi0";
    #environment.variables.KUBECONFIG = builtins.concatStringsSep ":" [
    #  "/home/alc/.kube/config"
    #  "/home/alc/.kube/rpi0"
    #  # Add more paths as needed
    #];

  };
}
