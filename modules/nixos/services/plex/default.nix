{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.plex.managed;
in
{
  options.services.plex.managed = {
    enable = mkEnableOption "Plex Media Server (managed as a Docker container)";
    
    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/plex";
      description = "Directory for Plex configuration";
    };
    
    mediaDir = mkOption {
      type = types.str;
      default = "/zpool/media/plex";
      description = "Root directory for media libraries";
    };
    
    transcodeDir = mkOption {
      type = types.str;
      default = "/tmp/plex-transcode";
      description = "Temporary transcode directory";
    };
  };

  config = mkIf cfg.enable {
    virtualisation.oci-containers.backend = "docker";

    # Ensure media user/group exists (if not already)
    users.users.media = {
      isSystemUser = true;
      group = "media";
    };
    users.groups.media = {};

    # Firewall rules for Plex
    networking.firewall = {
      allowedTCPPorts = [
        32400   # Plex web UI
      ];
      allowedUDPPorts = [
        1900    # DLNA
        32410
        32412
        32413
        32414   # GDM discovery
        5353    # mDNS
      ];
      allowedUDPPortRanges = [
        { from = 32410; to = 32414; }
      ];
    };

    # Directories with proper permissions
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0770 media media - -"
      "d ${cfg.transcodeDir} 0770 media media - -"
      "d ${cfg.mediaDir} 0770 root media - -"
    ];

    virtualisation.oci-containers.containers.plex = {
      image = "lscr.io/linuxserver/plex:latest";
      pull = "always";
      ports = [ "32400:32400/tcp" ];
      environment = {
        PUID = "983";
        PGID = "983";
        TZ = "Europe/Oslo";
        VERSION = "docker";
      };
      volumes = [
        "${cfg.dataDir}:/config"
        "${cfg.transcodeDir}:/transcode"
        "${cfg.mediaDir}:/media:ro"
      ];
      log-driver = "json-file";
      extraOptions = [
        "--log-opt=max-file=10"
        "--log-opt=max-size=2m"
      ];
    };

    systemd.services.docker-plex = {
      requires = [
        "zfs-mount.service"
        "torrent-shared-media-permissions.service"
      ];
      after = [
        "zfs-mount.service"
        "torrent-shared-media-permissions.service"
      ];
    };

    # Ensure Docker can access ZFS before starting
    systemd.services.docker = mkIf config.virtualisation.docker.enable {
      after = [
        "zfs-mount.service"
        "zfs-import.target"
        "zfs-auto-unlock.service"
      ];
      requires = [
        "zfs-mount.service"
        "zfs-auto-unlock.service"
      ];
    };
  };
}
