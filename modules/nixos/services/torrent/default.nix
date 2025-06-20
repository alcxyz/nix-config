# modules/nixos/services/torrent/default.nix
{ config, lib, pkgs, hostName, ... }:

let
  peer-port = 51413;
  web-port = 8112;
in

{
  services.rtorrent = {
    enable = true;
    port = peer-port;
    openFirewall = true;
    downloadDir = "/zpool/downloads";
  };
  
  services.flood = {
    enable = true;
    port = web-port;
    openFirewall = true;
    extraArgs = ["--rtsocket=${config.services.rtorrent.rpcSocket}"];
    #host = "127.0.0.1";
  };

  systemd.services.flood.serviceConfig.SupplementaryGroups = [ config.services.rtorrent.group ];

  # Traefik Routes for Flood
  services.traefik.dynamicConfigOptions.http = {
    routers.flood = {
      rule = "Host(`flood.${hostName}.local`)";
      entryPoints = [ "websecure" ];
      service = "flood";
      tls = true;
    };
    services.flood = {
      loadBalancer.servers = [{ url = "http://localhost:8112"; }];
    };
  };

  /*
  networking.firewall.allowedTCPPorts = [
    8112
    51413
  ];
  networking.firewall.allowedUDPPorts = [
    51413
  ];
  */
}
