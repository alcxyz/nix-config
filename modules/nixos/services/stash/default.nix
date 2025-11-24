# modules/nixos/services/stash/default.nix
{ config, lib, pkgs, username, hostName, ... }:

with lib;

let
  cfg = config.services.stash.managed;
  # We get the package from cfg.package, so stashBinary will use the configured one.
  stashBinary = "${cfg.package}/bin/stash";
in
{
  options.services.stash.managed = {
    enable = mkEnableOption "custom Stash.managed service";

    # Allow package to be configured, defaulting to pkgs.stash
    package = mkPackageOption pkgs "stash" { };

    user = mkOption {
      type = types.str;
      default = "stash";
      description = "User to run Stash.managed as.";
    };
    group = mkOption {
      type = types.str;
      default = "stash";
      description = "Group to run Stash.managed as.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/stash";
      description = "Directory for Stash.managed data (config.yml, database, etc.).";
    };
    mediaDir = mkOption {
      type = types.path;
      default = "/zpool/stash";
      description = "Directory where your Stash.managed media is located.";
    };
    port = mkOption {
      type = types.port;
      default = 9999;
      description = "Port for Stash.managed to listen on.";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to open the Stash.managed port in the firewall.";
    };
    autoStart = mkOption {
      type = types.bool;
      default = false;
      description = "Whether Stash.managed should start automatically on boot.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      extraGroups = [ "media" "rtorrent" ];
    };
    users.groups.${cfg.group} = {};

    users.users.${username}.extraGroups = [ cfg.group ];

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0750 ${cfg.user} ${cfg.group} - -"
      "d '${cfg.mediaDir}' 0775 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services."stash" = {
      description = "Stash.managed Application Service";
      requires = [ "zfs-mount.service" ];
      after = [ "zfs-mount.service" ];
      unitConfig = {
        RequiresMountsFor = [
          cfg.dataDir
          cfg.mediaDir
        ];
      };
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        ExecStart = ''
          ${stashBinary}
        '';
        Path = [ pkgs.coreutils pkgs.ffmpeg-full ];
        Restart = "on-failure";
        RestartSec = "10s";
        ProtectSystem = "full";
        PrivateTmp = true;
        ProtectHome = true;
        NoNewPrivileges = true;
      };
      wantedBy = if cfg.autoStart then [ "multi-user.target" ] else [];
    };

    services.traefik.dynamicConfigOptions.http.routers.stash = {
      rule = "Host(`stash.${hostName}.local`)";
      entryPoints = [ "websecure" ];
      service = "stash";
      tls = true;
    };
    services.traefik.dynamicConfigOptions.http.services.stash = {
      loadBalancer.servers =
        [ { url = "http://127.0.0.1:${toString cfg.port }"; } ];
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
