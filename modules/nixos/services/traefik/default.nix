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
        routers.api = {
          rule = "Host(`traefik.nux.local`)";
          entryPoints = [ "websecure" ];
          service = "api@internal";
          tls = true;
        };
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

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
