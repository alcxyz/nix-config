# modules/nixos/services/stash/default.nix
{ config, lib, pkgs, ... }:

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
    package = mkPackageOption pkgs "stash" { }; # Already here, good!

    user = mkOption {
      type = types.str;
      default = "stash-managed";
      description = "User to run Stash.managed as.";
    };
    group = mkOption {
      type = types.str;
      default = "stash-managed";
      description = "Group to run Stash.managed as.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/stash-managed";
      description = "Directory for Stash.managed data (config.yml, database, etc.).";
    };
    mediaDir = mkOption {
      type = types.path;
      default = "/hyperdisk/vault/stash";
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
    # === ENSURE STASH PACKAGE IS INSTALLED ===
    environment.systemPackages = [
      cfg.package # This will be pkgs.stash by default
    ];
    # =======================================

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      extraGroups = [ "deluge" ];
    };
    users.groups.${cfg.group} = {};

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0750 ${cfg.user} ${cfg.group} - -"
      "d '${cfg.mediaDir}' 0775 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services."stash-managed" = {
      description = "Stash.managed Application Service";
      after = [ "network.target" ];
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
        ''; # Uses the stashBinary defined in the let block
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

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
