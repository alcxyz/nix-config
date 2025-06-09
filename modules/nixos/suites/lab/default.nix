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

  # Options previously in lab/config.nix, now part of the suite's options
  # We namespace them under 'lab' to match how they were accessed in the old config.nix
  options.lab = with types; {
    enable = mkOption {
      type = types.bool;
      default = false; # Usually, if suites.lab.enable is true, this would also be true.
      description = "Enable specific lab system configurations (services, virtualization, firewall).";
    };
  };

  # Removed imports of config.nix and packages.nix

  config = mkIf cfg.enable { # This is suites.lab.enable
    # === Configurations previously in lab/config.nix ===
    # The mkIf config.lab.enable from the old config.nix is implicitly handled
    # if we assume that when suites.lab.enable is true, then lab.enable (the inner one) should also be true.

    services.k3s = {
      enable = true;
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
