# /modules/nixos/services/unbound/default.nix
{ config, lib, pkgs, ... }:

{
  # Use the built-in Unbound service
  services.unbound = {
    enable = true;
    settings = {
      server = {
        # Listen only on localhost, on port 5335
        interface = [ "0.0.0.0@5335" ];
        access-control = [ "127.0.0.1/32 allow" "172.17.0.0/16 allow" "172.18.0.0/16 allow" ];

        # DNSSEC validation and performance
        harden-dnssec-stripped = "yes";
        harden-below-nxdomain = "yes";
        aggressive-nsec = "yes";

        # Privacy and hardening
        qname-minimisation = "yes";
        hide-identity = "yes";
        hide-version = "yes";
        use-caps-for-id = "yes";

        # Performance tuning
        prefetch = "yes";
        num-threads = 5;
      };
    };
  };
  networking.firewall = {
    enable = true;
    # ... other rules ...
    allowedUDPPorts = [
      53
      5335
    ];
  };
}
