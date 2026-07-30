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
  calibreConfigDir = "/var/lib/calibre/config";
  calibreWebPort = 8083;
  calibreWebFirewallRules =
    lib.concatMapStringsSep "\n" (ip: ''
      iptables -A nixos-fw -p tcp --dport ${toString calibreWebPort} -s ${ip} -j nixos-fw-accept
    '')
    cfg.proxySources;
  calibreWebStateSetup = pkgs.writeShellScript "calibre-web-state-setup" ''
    set -euo pipefail

    install -d -m 0755 -o ${lib.escapeShellArg username} -g users ${lib.escapeShellArg cfg.configDir}
    install -d -m 0755 -o ${lib.escapeShellArg username} -g users ${lib.escapeShellArg calibreConfigDir}

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

    proxySources = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Source addresses allowed to reach Calibre-Web.";
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.extraCommands = lib.mkAfter ''
      ${calibreWebFirewallRules}
    '';

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
        port = calibreWebPort;
      };
      options = {
        calibreLibrary = cfg.libraryDir;
        enableBookUploading = false;
      };
    };

    systemd.services.calibre-web = {
      conflicts = [ "docker-calibre-web.service" ];
      serviceConfig.ExecStartPre = lib.mkBefore [ "+${calibreWebStateSetup}" ];
    };
  };
}
