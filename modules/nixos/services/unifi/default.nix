# /modules/nixos/services/unifi/default.nix
{ config, lib, pkgs, ... }:

{
  # Use the built-in UniFi service
  services.unifi = {
    enable = true;
    openFirewall = true;
  };

  # Traefik Routes for Unifi
  services.traefik.dynamicConfigOptions.http = {
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
  };

  networking.firewall.allowedTCPPorts = [ 8443 ];

}
