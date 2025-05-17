{
  options, config, lib, pkgs, username, ... }:
with lib;
{
  options.services.deluge = mkOption {
    type = types.bool;
    default = false;
    description = "Enable the Deluge system service."; # Updated description and option path
  };

  config = mkIf config.services.deluge {
    services.deluge = {
      enable = true;
      user = "${username}"; # Use passed username
      group = "${config.users.users.${username}.group}"; # Use the user's primary group
      dataDir = "/home/${username}"; # Assuming this is the desired data directory, using username
      web.enable = true;
    };

    systemd.services.deluged = {
      # Consider adding explicit dependencies here if needed, e.g.,
      # after = [ "zfs-import-hyperdisk.service" "zfs-import-fundrive.service" ];
      # This would depend on whether you re-enabled the ZFS import services or added alternative waits.
      after = [ "zfs-mount.service" ]; # Keep original dependency for now
    };

    environment.systemPackages = with pkgs; [
      deluge
    ];

    # Explicitly open necessary firewall ports for Deluge
    networking.firewall.allowedTCPPorts = [
      8112 # Deluge web UI
      51413 # Deluge daemon
    ];

  };
}