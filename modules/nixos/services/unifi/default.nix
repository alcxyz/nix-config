# /modules/nixos/services/unifi/default.nix
{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.unifi-traefik;
in
{
  options.services.unifi-traefik = {
    enable = mkEnableOption "UniFi with Traefik integration";
    domain = mkOption {
      type = types.str;
      description = "Domain to host the UniFi web UI on.";
      example = "unifi.nux.local";
    };
  };

  config = mkIf cfg.enable {
    # Use the built-in UniFi service
    services.unifi = {
      enable = true;
      openFirewall = true;
    };

    # Add Traefik integration
    services.traefik.dynamicConfigOptions.http = {
      routers.unifi = {
        rule = "Host(`${cfg.domain}`)";
        entryPoints = [ "websecure" ];
        service = "unifi";
        tls.certResolver = "letsencrypt";
      };
      services.unifi = {
        loadBalancer.servers = [{
          url = "https://localhost:8443";
        }];
        loadBalancer.serversTransport = "unifi-transport";
      };
      serversTransports.unifi-transport = {
        insecureSkipVerify = true;
      };
    };
  };
}
