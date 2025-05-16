{ options, config, lib, pkgs, ... }:
with lib;
{
  options.services.calibre-web.enableOption = mkOption {
    type = types.bool;
    default = false;
    description = "Enable the Calibre-Web service configuration.";
  };

  config = mkIf config.services.calibre-web.enableOption {
    services.calibre-web = {
      enable = true;
      user = "${config.user.name}"; # Assuming user 'alc' is configured at host level
      dataDir = "/hyperdisk/vault/calibre/calibre_web/config";
      options.calibreLibrary = "/hyperdisk/vault/calibre/calibre/config/libraries/Main";
      listen = {
        ip = "0.0.0.0";
        port = 8083;
      };
      openFirewall = true;
    };

    systemd.services.calibre-web = {
      after = [ "zfs-mount.service" ]; # Assuming zfs-mount is relevant
    };

    environment.systemPackages = with pkgs; [
      calibre
      calibre-web
    ];

    # Firewall rule will be handled in the main host config or a separate networking module if preferred
    # For now, let's keep the service definition separate from the firewall rule.
    # The original had openFirewall = true; which might automatically add the rule.
    # We'll rely on that or add it explicitly in the host config if needed.
  };
}
