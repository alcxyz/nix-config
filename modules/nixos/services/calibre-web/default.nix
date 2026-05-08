{
  config,
  lib,
  username,
  ...
}:

with lib;

let
  cfg = config.services.calibre-web.managed;
in
{
  options.services.calibre-web.managed = {
    enable = mkEnableOption "Calibre-Web managed as a native systemd service";

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
    networking.firewall.allowedTCPPorts = [ 8083 ];

    systemd.tmpfiles.rules = [
      "d ${cfg.configDir} 0755 ${username} users - -"
      "d ${cfg.libraryDir} 0755 ${username} users - -"
    ];

    services.calibre-web = {
      enable = true;
      dataDir = toString cfg.configDir;
      user = username;
      group = "users";
      listen = {
        ip = "0.0.0.0";
        port = 8083;
      };
      options = {
        calibreLibrary = cfg.libraryDir;
        enableBookUploading = false;
      };
    };

    systemd.services.calibre-web = {
      requires = [ "zfs-mount.service" ];
      after = [ "zfs-mount.service" ];
      conflicts = [ "docker-calibre-web.service" ];
    };
  };
}
