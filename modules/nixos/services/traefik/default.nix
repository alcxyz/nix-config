# /modules/nixos/services/traefik/default.nix
{ config, lib, pkgs, ... }:

{
  # Use the built-in Traefik service directly
  services.traefik = {
    enable = true;
    staticConfigOptions = {
      entryPoints = {
        web.address = ":80";
        websecure.address = ":443";
      };
      certificatesResolvers.letsencrypt.acme = {
        email = "post@alc.no";
        storage = "/var/lib/traefik/acme.json";
        tlsChallenge = true;
      };
    };
    dynamicConfigOptions = {
      http = {
        # Dashboard
        routers.api = {
          rule = "Host(`traefik.nux.local`)";
          entryPoints = [ "websecure" ];
          service = "api@internal";
          tls.certResolver = "letsencrypt";
        };
        # Redirect all HTTP traffic to HTTPS
        middlewares.https-redirect.redirectScheme = {
          scheme = "https";
          permanent = true;
        };
        routers.http-catchall = {
          rule = "HostRegexp(`{host:.+}`)";
          entryPoints = [ "web" ];
          middlewares = [ "https-redirect" ];
        };
      };
    };
  };

  # Open firewall ports
  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
