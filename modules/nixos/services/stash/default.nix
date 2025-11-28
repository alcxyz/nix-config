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
      pkgs.ffmpeg-full
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

    systemd.services.stash = {
      description = "Stash.managed Application Service";

      # Ensure ZFS mounts are ready and ordered
      requires = [
        "zfs-import.target"
        "zfs-mount.service"
      ];
      after = [
        "zfs-import.target"
        "zfs-mount.service"
      ];

      # This ensures systemd pulls in the mount units for these paths and waits
      unitConfig.RequiresMountsFor = [
        cfg.dataDir
        cfg.mediaDir
      ];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;

        # Optional preflight check: make sure mediaDir exists and is readable
        ExecStartPre = [
          "${pkgs.coreutils}/bin/test -d ${cfg.dataDir}"
          "${pkgs.coreutils}/bin/test -d ${cfg.mediaDir}"
        ];

        # Use absolute path; stashBinary is already absolute
        ExecStart = "${stashBinary}";

        # Do NOT use 'Path' here; not a valid systemd key. If you need PATH:
        Environment = [
          "PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.ffmpeg-full ]}"
        ];

        Restart = "on-failure";
        RestartSec = "10s";

        # Hardening (adjust if Stash needs write under /usr)
        ProtectSystem = "full";
        PrivateTmp = true;
        ProtectHome = true;
        NoNewPrivileges = true;
      };

      wantedBy = lib.mkIf cfg.autoStart [ "multi-user.target" ];
    };

    #systemd.services."stash" = {
    #  description = "Stash.managed Application Service";
    #  requires = [ "zfs-mount.service" ];
    #  after = [ "zfs-mount.service" ];
    #  unitConfig = {
    #    RequiresMountsFor = [
    #      cfg.dataDir
    #      cfg.mediaDir
    #    ];
    #  };
    #  serviceConfig = {
    #    Type = "simple";
    #    User = cfg.user;
    #    Group = cfg.group;
    #    WorkingDirectory = cfg.dataDir;
    #    ExecStart = ''
    #      ${stashBinary}
    #    '';
    #    Path = [ pkgs.coreutils pkgs.ffmpeg-full ];
    #    Restart = "on-failure";
    #    RestartSec = "10s";
    #    ProtectSystem = "full";
    #    PrivateTmp = true;
    #    ProtectHome = true;
    #    NoNewPrivileges = true;
    #  };
    #  wantedBy = if cfg.autoStart then [ "multi-user.target" ] else [];
    #};

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
