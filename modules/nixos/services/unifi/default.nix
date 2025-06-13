# /modules/nixos/services/unifi/default.nix
{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.unifi;
in
{
  options.services.unifi = {
    enable = mkEnableOption "UniFi Network Application";
    domain = mkOption {
      type = types.str;
      description = "Domain to host the UniFi web UI on.";
      example = "unifi.nux.local";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open firewall ports required for UniFi device communication.";
    };
  };

  config = mkIf cfg.enable {
    # Enable the UniFi service
    services.unifi.enable = true;

    # Open ports for device adoption and management
    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ 8080 8443 8880 8843 6789 ];
      allowedUDPPorts = [ 3478 5514 10001 1900 ];
    };

    # Tell Traefik how to find UniFi
    services.traefik.dynamicConfigOptions.http = {
      routers.unifi = {
        rule = "Host(`${cfg.domain}`)";
        entryPoints = [ "websecure" ];
        service = "unifi";
        tls.certResolver = "letsencrypt";
      };
      services.unifi = {
        loadBalancer.servers = [{
          # UniFi serves on HTTPS locally
          url = "httpss://localhost:8443";
        }];
        # Traefik needs to trust the self-signed cert UniFi uses internally
        loadBalancer.serversTransport.insecureSkipVerify = true;
      };
    };
  };
}
