{
  config,
  lib,
  pkgs,
  username,
  ...
}:

with lib;

let
  cfg = config.services.calibre-web.managed;
  appdataConfigDir = "/zpool/appdata/calibre-web/config";
  legacyConfigDir = "/zpool/vault/calibre/calibre_web/config";
  calibreConfigDir = "/var/lib/calibre/config";
  legacyCalibreConfigDir = "/zpool/vault/calibre/calibre/config";
  calibreWebStateMigration = pkgs.writeShellScript "calibre-web-state-migration" ''
    set -euo pipefail

    install -d -m 0755 -o ${lib.escapeShellArg username} -g users ${lib.escapeShellArg cfg.configDir}
    install -d -m 0755 -o ${lib.escapeShellArg username} -g users ${lib.escapeShellArg calibreConfigDir}

    config_marker=${lib.escapeShellArg (toString cfg.configDir + "/.migrated-from-zpool")}
    if [ ! -e "$config_marker" ]; then
      if [ -d ${lib.escapeShellArg appdataConfigDir} ]; then
        ${lib.getExe pkgs.rsync} -a \
          ${lib.escapeShellArg (appdataConfigDir + "/")} \
          ${lib.escapeShellArg (toString cfg.configDir + "/")}
      elif [ -d ${lib.escapeShellArg legacyConfigDir} ]; then
        ${lib.getExe pkgs.rsync} -a \
          ${lib.escapeShellArg (legacyConfigDir + "/")} \
          ${lib.escapeShellArg (toString cfg.configDir + "/")}
      fi
      touch "$config_marker"
    fi

    calibre_marker=${lib.escapeShellArg (calibreConfigDir + "/.migrated-from-zpool")}
    if [ -d ${lib.escapeShellArg legacyCalibreConfigDir} ] && [ ! -e "$calibre_marker" ]; then
      ${lib.getExe pkgs.rsync} -a \
          ${lib.escapeShellArg (legacyCalibreConfigDir + "/")} \
          ${lib.escapeShellArg (calibreConfigDir + "/")}
      touch "$calibre_marker"
    fi

    chown -R ${lib.escapeShellArg username}:users ${lib.escapeShellArg cfg.configDir}
    chown -R ${lib.escapeShellArg username}:users ${lib.escapeShellArg calibreConfigDir}
  '';
in
{
  options.services.calibre-web.managed = {
    enable = mkEnableOption "Calibre-Web managed as a native systemd service";

    configDir = mkOption {
      type = types.path;
      default = "/var/lib/calibre-web/config";
      description = "Calibre-Web configuration directory.";
    };

    libraryDir = mkOption {
      type = types.path;
      default = "/var/lib/calibre/config/libraries/Main";
      description = "Calibre library directory exposed to Calibre-Web.";
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ 8083 ];

    systemd.tmpfiles.rules = [
      "d ${cfg.configDir} 0755 ${username} users - -"
      "d ${calibreConfigDir} 0755 ${username} users - -"
      "d ${cfg.libraryDir} 0755 ${username} users - -"
    ];

    system.activationScripts.calibreWebStateDirs = ''
      install -d -m 0755 -o ${lib.escapeShellArg username} -g users ${lib.escapeShellArg cfg.configDir}
      install -d -m 0755 -o ${lib.escapeShellArg username} -g users ${lib.escapeShellArg calibreConfigDir}
      install -d -m 0755 -o ${lib.escapeShellArg username} -g users ${lib.escapeShellArg cfg.libraryDir}
    '';

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
      conflicts = [ "docker-calibre-web.service" ];
      serviceConfig.ExecStartPre = lib.mkBefore [ "+${calibreWebStateMigration}" ];
    };
  };
}
