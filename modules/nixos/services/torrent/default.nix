# modules/nixos/services/torrent/default.nix
{ config, lib, pkgs, ... }:

{
  services.rtorrent = {
    enable = true;
    downloadDir = "/downloads";
    openFirewall = true;
    port = 51413;
  };
  
  services.flood = {
    enable = true;
    openFirewall = true;
    port = 8112;
  };

  # Traefik Routes for Flood
  services.traefik.dynamicConfigOptions.http = {
    routers.flood = {
      rule = "Host(`deluge.xyz.local`)";
      entryPoints = [ "websecure" ];
      service = "flood";
      tls = true;
    };
    services.flood = {
      loadBalancer.servers = [{ url = "http://localhost:8112"; }];
    };
  };

  networking.firewall.allowedTCPPorts = [
    8112
    51413
  ];
  networking.firewall.allowedUDPPorts = [
    51413
  ];
}
