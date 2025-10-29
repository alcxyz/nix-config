# modules/nixos/services/calibre-web/default.nix
{ options, config, lib, pkgs, username, hostName, ... }:
with lib;
{
  config = mkIf config.services.calibre-web.enable {
    services.calibre-web = {
      user = "${username}";
      dataDir = "/zpool/vault/calibre/calibre_web/config";
      options.calibreLibrary = "/zpool/vault/calibre/calibre/config/libraries/Main";
      listen = {
        ip = "0.0.0.0";
        port = 8083;
      };
      openFirewall = true;
    };

    # HARD dependency: require zfs-mount.service to succeed
    systemd.services.calibre-web = {
      requires = [ "zfs-mount.service" ];
      after = [ "zfs-mount.service" ];
    };

    environment.systemPackages = with pkgs; [
      calibre
      calibre-web
    ];

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
