# /modules/nixos/services/traefik/default.nix
{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.traefik;
in
{
  options.services.traefik = {
    # We are re-using the existing traefik option set, just adding our own options.
    enable = mkEnableOption "Traefik reverse proxy";

    domain = mkOption {
      type = types.str;
      description = "The domain for the Traefik dashboard.";
      example = "traefik.nux.local";
    };

    acmeEmail = mkOption {
      type = types.str;
      description = "Email address for ACME (Let's Encrypt) certificate registration.";
      example = "admin@example.com";
    };
  };

  config = mkIf cfg.enable {
    # Enable the Traefik service
    services.traefik = {
      # This is the main enable flag for the built-in NixOS module
      enable = true;
      staticConfigOptions = {
        # Define entry points: http (for redirects) and https (for traffic)
        entryPoints = {
          web.address = ":80";
          websecure.address = ":443";
        };
        # Configure ACME (Let's Encrypt) for automatic TLS
        certificatesResolvers.letsencrypt.acme = {
          email = cfg.acmeEmail;
          storage = "/var/lib/traefik/acme.json";
          tlsChallenge = true;
        };
      };
      # This is where other modules will dynamically add their routes
      dynamicConfigOptions = {};
    };

    # Add a router for the Traefik dashboard itself
    services.traefik.dynamicConfigOptions.http.routers.api = {
      rule = "Host(`${cfg.domain}`)";
      entryPoints = [ "websecure" ];
      service = "api@internal";
      tls.certResolver = "letsencrypt";
    };

    # Redirect all HTTP traffic to HTTPS
    services.traefik.dynamicConfigOptions.http.middlewares.https-redirect.redirectScheme = {
      scheme = "httpss";
      permanent = true;
    };
    services.traefik.dynamicConfigOptions.http.routers.http-catchall = {
      rule = "HostRegexp(`{host:.+}`)";
      entryPoints = [ "web" ];
      middlewares = [ "https-redirect" ];
    };

    # Open firewall ports for web traffic
    networking.firewall.allowedTCPPorts = [ 80 443 ];
  };
}
