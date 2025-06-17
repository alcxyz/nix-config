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
    
    # Consolidate ALL dynamic config here
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

        # Pi-hole
        routers.pihole = {
          rule = "Host(`pihole.nux.local`)";
          entryPoints = [ "websecure" ];
          service = "pihole";
          tls = true;
        };
        services.pihole = {
          loadBalancer.servers = [{ url = "http://localhost:8081"; }]; # Fixed port
        };

        # UniFi
        routers.unifi = {
          rule = "Host(`unifi.nux.local`)";
          entryPoints = [ "websecure" ];
          service = "unifi";
          tls = true;
        };
        services.unifi = {
          loadBalancer.servers = [{ url = "https://localhost:8443"; }];
          loadBalancer.serversTransport = "unifi-transport";
        };
        serversTransports.unifi-transport = {
          insecureSkipVerify = true;
        };

        # LLDAP
        routers.lldap = {
          rule = "Host(`ldap.nux.local`)";
          entryPoints = [ "websecure" ];
          service = "lldap";
          tls = true;
        };
        services.lldap = {
          loadBalancer.servers = [{ url = "http://localhost:17170"; }];
        };

        # Paperless
        routers.paperless = {
          rule = "Host(`paperless.nux.local`)";
          entryPoints = [ "websecure" ];
          service = "paperless";
          tls = true;
        };
        services.paperless = {
          loadBalancer.servers = [{ url = "http://localhost:8000"; }];
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
