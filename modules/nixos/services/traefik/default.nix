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
        # Use a reliable public DNS to prevent startup loops with Pi-hole
        dnsChallenge.resolvers = [ "1.1.1.1:53" "8.8.8.8:53" ];
      };
      # --- AND THIS ---
      # Enable the API so the dashboard router can use it
      api.dashboard = true;
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
          # A router must have a service, even if it's just for redirection.
          service = "noop@internal";
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
