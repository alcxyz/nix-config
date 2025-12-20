# nix-config/modules/nixos/suites/gaming/default.nix
{ config, lib, pkgs, username, ... }:
{
  options.suites.gaming.enable = lib.mkEnableOption "Gaming Infrastructure";

  config = lib.mkIf config.suites.gaming.enable {
    # Controller and Steam hardware support
    hardware.steam-hardware.enable = true;
    boot.kernelModules = [ "uinput" ];
    
    services.udev.extraRules = ''
      # Grant user access to uinput for Steam Input and Sunshine controller emulation
      KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"
      # Input device permissions
      KERNEL=="event*", GROUP="input", MODE="0664"
      KERNEL=="js*", GROUP="input", MODE="0664"
    '';

    # Network ports for Sunshine and Steam Remote Play
    networking.firewall = {
      allowedTCPPorts = [ 47984 47989 48010 ];
      allowedUDPPorts = [ 47998 47999 48000 48002 48010 27031 27036 ];
    };

    # Ensure Flatpaks can talk to the host's Pipewire/Portals
    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-hyprland ];
    };
  };
}
