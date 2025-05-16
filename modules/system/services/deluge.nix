{ options, config, lib, pkgs, ... }:
with lib;
{
  options.services.deluge.enableOption = mkOption {
    type = types.bool;
    default = false;
    description = "Enable the Deluge service configuration.";
  };

  config = mkIf config.services.deluge.enableOption {
    services.deluge = {
      enable = true;
      user = "${config.user.name}"; # Assuming user 'alc' is configured at host level
      group = "users";
      dataDir = "/home/alc"; # Assuming /home/alc is the data directory
      web.enable = true;
    };

    systemd.services.deluged = {
      after = [ "zfs-mount.service" ]; # Assuming zfs-mount is relevant
    };

    environment.systemPackages = with pkgs; [
      deluge
    ];

    # Firewall rules will be handled in the main host config or a separate networking module if preferred
    # The original had allowedTCPPorts for 8112 and 51413.
    # We'll add these explicitly in the host config if needed.
  };
}
