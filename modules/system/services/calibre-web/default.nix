{ options, config, lib, pkgs, username, ... }:
with lib;
{
  # Removed options.services.calibre-web.enable definition

  config = mkIf config.services.calibre-web.enable {
    services.calibre-web = {
      # enable = true; # REMOVED: This was causing recursion.
      user = "${username}"; 
      dataDir = "/hyperdisk/vault/calibre/calibre_web/config";
      options.calibreLibrary = "/hyperdisk/vault/calibre/calibre/config/libraries/Main";
      listen = {
        ip = "0.0.0.0";
        port = 8083;
      };
      openFirewall = true;
    };

    systemd.services.calibre-web = {
      after = [ "zfs-mount.service" ];
    };

    environment.systemPackages = with pkgs; [
      calibre
      calibre-web
    ];
  };
}
