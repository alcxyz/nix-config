{ options, config, lib, pkgs, ... }:
with lib;
let
  cfg = config.suites.lab; # This refers to options.suites.lab
  # For options defined within *this* module (like lab.enable below)
  # we refer to them via config.lab inside the config block.

in
{
  # Option for enabling the entire suite
  options.suites.lab = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the lab suite configurations.";
    };
  };

  config = mkIf cfg.enable {

    services.k3s = {
      enable = false;
      role = "server";
      extraFlags = toString [
        #"--flannel-iface=br0" # Crucial: Tells Flannel (default CNI) to use br0.
        #"--flannel-backend=none"
        # "--node-ip 192.168.1.100"
        # "--kubelet-arg=v=4"
      ];
    };

    services.rpcbind.enable = true;

    virtualisation.containers.enable = true;
    /*
    virtualisation.podman = {
      enable = true;
      #dockerCompat = true;
      defaultNetwork.settings.dns_enabled = true;
    };
    */

    virtualisation.docker = {
      enable = true;
      rootless.enable = true;
      rootless.setSocketVariable = true;
    };

    #boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

    networking.firewall.allowedTCPPorts = [
      6443 # k3s
      # 2379 # k3s, etcd clients
      # 2380 # k3s, etcd peers
    ];
    networking.firewall.allowedUDPPorts = [
      # 8472 # k3s, flannel
    ];

    # === Packages previously in lab/packages.nix ===
    environment.systemPackages = with pkgs; [
      terraform
      opentofu
      ansible
      k3s
      kubectl
      kubernetes-helm
      kubeswitch
      k9s
      cockpit
      podman-compose
      lima
    ];
  };
}
