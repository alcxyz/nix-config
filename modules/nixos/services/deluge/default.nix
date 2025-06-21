# modules/nixos/services/deluge/default.nix
{ config, lib, pkgs, hostName, ... }:

{
  services.deluge = {
    enable = true;
    #user = "deluge";
    #group = "deluge";
    #dataDir = "/vault/deluge";
    openFirewall = true;
    web.enable = true;
    #web.port = 8112;
  };

  # Traefik Routes for Deluge
  services.traefik.dynamicConfigOptions.http = {
    routers.delugeweb = {
      rule = "Host(`deluge.${hostName}.local`)";
      entryPoints = [ "websecure" ];
      service = "delugeweb";
      tls = true;
    };
    services.delugeweb = {
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
