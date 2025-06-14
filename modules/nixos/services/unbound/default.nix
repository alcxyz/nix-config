# /modules/nixos/services/unbound/default.nix
{ config, lib, pkgs, ... }:

{
  # Use the built-in Unbound service
  services.unbound = {
    enable = true;
    settings = {
      server = {
        # Listen only on localhost, on port 5335
        interface = [ "127.0.0.1@5335" ];
        access-control = [ "127.0.0.1/32 allow" ];

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
}
