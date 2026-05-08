{
  config,
  lib,
  ...
}:

with lib;

let
  cfg = config.services.calibre-web.managed;
in
{
  options.services.calibre-web.managed = {
    enable = mkEnableOption "Calibre-Web (managed as a Docker container)";

    configDir = mkOption {
      type = types.path;
      default = "/zpool/vault/calibre/calibre_web/config";
      description = "Calibre-Web configuration directory.";
    };

    libraryDir = mkOption {
      type = types.path;
      default = "/zpool/vault/calibre/calibre/config/libraries/Main";
      description = "Calibre library directory exposed to Calibre-Web.";
    };
  };

  config = mkIf cfg.enable {
    virtualisation.oci-containers.backend = "docker";

    networking.firewall.allowedTCPPorts = [ 8083 ];

    systemd.tmpfiles.rules = [
      "d ${cfg.configDir} 0755 1000 100 - -"
      "d ${cfg.libraryDir} 0755 1000 100 - -"
    ];

    virtualisation.oci-containers.containers.calibre-web = {
      image = "lscr.io/linuxserver/calibre-web:latest";
      pull = "always";
      ports = [ "8083:8083/tcp" ];
      environment = {
        PUID = "1000";
        PGID = "100";
        TZ = "Europe/Oslo";
        DOCKER_MODS = "";
        OAUTHLIB_RELAX_TOKEN_SCOPE = "1";
      };
      volumes = [
        "${cfg.configDir}:/config"
        "${cfg.libraryDir}:/books"
      ];
      log-driver = "json-file";
      extraOptions = [
        "--log-opt=max-file=10"
        "--log-opt=max-size=2m"
      ];
    };

    systemd.services.docker-calibre-web = {
      requires = [ "zfs-mount.service" ];
      after = [ "zfs-mount.service" ];
    };
  };
}
