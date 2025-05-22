# modules/nixos/services/deluge/default.nix
{
  options, config, lib, pkgs, username, ... }: # Keep username if it's used elsewhere, but we won't use it for Deluge user
with lib;
{
  config = mkIf config.services.deluge.enable {
    services.deluge = {
      # No need to explicitly set user and group here.
      # NixOS defaults to a 'deluge' user/group which is what we want.
      # user = "${username}"; # REMOVE THIS LINE
      # group = "${config.users.users.${username}.group}"; # REMOVE THIS LINE

      # Set dataDir to a more appropriate system location, e.g., /var/lib/deluge
      # This directory will be owned by the 'deluge' user automatically by NixOS.
      user = "deluge";
      group = "deluge";
      dataDir = "/hyperdisk/vault/deluge"; # CHANGE THIS LINE from /home/${username}
      web.enable = true;
    };

    systemd.services.deluged = {
      # Ensure deluged starts after your ZFS mount, assuming /fundrive is on ZFS
      after = [ "zfs-mount.service" ];
      # We might also want to ensure the download directory exists and has correct permissions
      # This is more robustly handled with preStart, or through external setup/manual chown/chmod
      # but let's do it manually for now as it's a one-time change.
    };

    # The rest of your configuration (firewall, packages) can remain the same
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
