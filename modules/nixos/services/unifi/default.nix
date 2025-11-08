# /modules/nixos/services/unifi/default.nix
{ config, lib, pkgs, hostName, ... }:

{
  # Use the built-in UniFi service
  services.unifi = {
    enable = true;
    openFirewall = true;
  };

  # Traefik routing is now in Docker traefik file provider
  # Routes defined in: /nuc/traefik/traefik-config/systemd-services.yml.tpl

  networking.firewall.allowedTCPPorts = [ 8443 ];

}
