{ options, config, lib, pkgs, username, ... }:
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
      user = "${username}"; # Assuming username is passed as specialArgs
      group = "users"; # Assuming 'users' group exists and is appropriate
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

    # Firewall rules for Deluge will need to be opened in the main host config or a networking module.
    # The ports from the original config were 8112 (web) and 51413 (daemon).
  };
}