# /modules/nixos/services/unifi/default.nix
{ config, lib, pkgs, ... }:

{
  # Use the built-in UniFi service
  services.unifi = {
    enable = true;
    openFirewall = true;
  };

}
