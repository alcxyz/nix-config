{ options, config, lib, pkgs, username, ... }:
with lib;
{
  options.services.calibre-web.enable = mkOption {
    type = types.bool;
    default = false;
    description = "Enable the Calibre-Web system service.";
  };

  config = mkIf config.services.calibre-web.enable {
    # This services.calibre-web refers to the actual NixOS service options
    services.calibre-web = {
      enable = true; # This enables the Calibre-Web service itself
      user = "${username}"; # Assuming username is passed as specialArgs
      dataDir = "/hyperdisk/vault/calibre/calibre_web/config";
      options.calibreLibrary = "/hyperdisk/vault/calibre/calibre/config/libraries/Main";
      listen = {
        ip = "0.0.0.0";
        port = 8083;
      };
      openFirewall = true;
    };

    systemd.services.calibre-web = {
      # Consider adding explicit dependencies here if needed, e.g.,
      # after = [ "zfs-import-hyperdisk.service" "zfs-import-fundrive.service" ];
      # This would depend on whether you re-enabled the ZFS import services or added alternative waits.
      after = [ "zfs-mount.service" ]; # Keep original dependency for now
    };

    environment.systemPackages = with pkgs; [
      calibre
      calibre-web
    ];

    # The openFirewall = true; option on services.calibre-web should handle the firewall rule automatically.
  };
}
