{ options, config, lib, pkgs, username, hostName, ... }:
with lib;
{
  # Removed options.services.calibre-web.enable definition

  config = mkIf config.services.calibre-web.enable {
    services.calibre-web = {
      # enable = true; # REMOVED: This was causing recursion.
      user = "${username}"; 
      dataDir = "/zpool/vault/calibre/calibre_web/config";
      options.calibreLibrary = "/zpool/vault/calibre/calibre/config/libraries/Main";
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

    # Traefik Routes for calibre-web
    services.traefik.dynamicConfigOptions.http = {
      routers.calibre-web = {
        rule = "Host(`calibre-web.${hostName}.local`)";
        entryPoints = [ "websecure" ];
        service = "calibre-web";
        tls = true;
      };
      services.calibre-web = {
        loadBalancer.servers = [{ url = "http://localhost:8083"; }];
      };
    };
  };
}
