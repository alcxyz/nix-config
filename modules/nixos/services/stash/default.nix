# modules/nixos/services/stash/default.nix
{ config, lib, pkgs, ... }:

with lib;

let
  # Define the dedicated user and group for Stash within this module
  # This makes it self-contained and avoids hardcoding "stash" elsewhere.
  stashUser = "stash";
  stashGroup = "stash";

in
{
  # Only enable the Stash service if config.services.stash.enable is true
  config = mkIf config.services.stash.enable {
    # Define the Stash service using the built-in Nixpkgs definition
    services.stash = {
      enable = true; # Enabled here within the module
      user = stashUser;
      group = stashGroup;

      # The data directory where Stash stores its database, cache, generated files, etc.
      # This directory will be created and owned by stash:stash automatically by NixOS.
      dataDir = "/hyperdisk/vault/stash";

      # The directories where Stash finds your media.
      # Make sure this path is accessible by the 'stash' user.
      scriptDirectories = [ "/hyperdisk/stash" ]; # Deluge's download path

      # The port Stash listens on.
      port = 9999; # Default, adjust if you need a different port

      # Optional: Add extra arguments if needed
      # extraArguments = [ "--logfile" "/var/log/stash/stash.log" ];

      # Ensure Stash starts after necessary mounts are available.
      # This is crucial if your /fundrive is a separate filesystem (e.g., ZFS, btrfs, external drive).
      extraSystemdServiceConfig = {
        RequiresMountsFor = [ "/hyperdisk/stash" ];
        # If you have a specific systemd mount unit for /fundrive (e.g. mnt-fundrive.mount),
        # or a ZFS pool, you might also use: After = [ "zfs-mount.service" ];
      };
    };

    # Firewall rules specific to Stash
    networking.firewall.allowedTCPPorts = [
      config.services.stash.port # Uses the port defined above
    ];

    # Define the system user and group for Stash.
    # This ensures they exist and allows us to add them to other groups.
    users.users.${stashUser} = {
      isSystem = true;
      group = stashGroup;
      # Add the 'stash' user to the 'deluge' group so it can read files
      # downloaded by Deluge. This assumes your Deluge module also defines a 'deluge' group.
      extraGroups = [ "deluge" ]; # IMPORTANT for cross-service access
    };
    users.groups.${stashGroup} = {}; # Define the stash group

    # If you use the 'media' group strategy, you would do this instead:
    # users.users.${stashUser}.extraGroups = [ "media" ]; # instead of "deluge"
  };
}
