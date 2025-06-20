# /modules/nixos/services/traefik/default.nix
{ config, lib, pkgs, ... }:

{
  services.traefik = {
    enable = true;

    staticConfigOptions = {
      entryPoints = {
        web.address = ":80";
        websecure.address = ":443";
      };
      api.dashboard = true;
    };

    dynamicConfigOptions = {
      http = {
        # Traefik Dashboard
        routers.api = {
          rule = "Host(`traefik.nux.local`)";
          entryPoints = [ "websecure" ];
          service = "api@internal";
          tls = true;
        };

        # HTTPS Redirect
        middlewares.https-redirect.redirectScheme = {
          scheme = "https";
          permanent = true;
        };
        routers.http-catchall = {
          rule = "HostRegexp(`{host:.+}`)";
          entryPoints = [ "web" ];
          middlewares = [ "https-redirect" ];
          service = "noop@internal";
        };

      };
    };
  };

  # Open firewall ports for Traefik
  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
