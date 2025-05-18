{
  options, config, lib, pkgs, username, ... }:
with lib;
{
  # Removed options.services.deluge.enable definition
  # The option services.deluge.enable is defined by the main NixOS Deluge module.

  config = mkIf config.services.deluge.enable {
    services.deluge = {
      # enable = true; # REMOVED: This was causing recursion. The outer mkIf handles enablement.
      user = "${username}";
      group = "${config.users.users.${username}.group}";
      dataDir = "/home/${username}";
      web.enable = true;
    };

    systemd.services.deluged = {
      after = [ "zfs-mount.service" ];
    };

    environment.systemPackages = with pkgs; [
      deluge
    ];

    networking.firewall.allowedTCPPorts = [
      8112 # Deluge web UI
      51413 # Deluge daemon
    ];
    networking.firewall.allowedUDPPorts = [
      51413 # Deluge daemon also uses UDP
    ];

  };
}