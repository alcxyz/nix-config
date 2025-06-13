# /modules/nixos/services/unbound/default.nix
{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.unbound;
in
{
  options.services.unbound = {
    enable = mkEnableOption "Unbound recursive DNS resolver";
  };

  config = mkIf cfg.enable {
    # Enable the built-in NixOS Unbound service
    services.unbound = {
      enable = true;
      # The NixOS module automatically provides and updates the root hints file.
      settings = {
        server = {
          # Listen only on localhost, on port 5335.
          # This is crucial so only local services (like Pi-hole) can use it.
          interface = [ "127.0.0.1@5335" ];
          # Only allow queries from localhost.
          access-control = [ "127.0.0.1/32 allow" ];

          # Enable DNSSEC validation and aggressive NSEC caching for performance.
          harden-dnssec-stripped = "yes";
          harden-below-nxdomain = "yes";
          aggressive-nsec = "yes";

          # Privacy and hardening options
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

    # No firewall port is needed, as Unbound is only accessible from localhost.
  };
}
