{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.plex.managed;
in
{
  options.services.plex.managed = {
    enable = mkEnableOption "Plex Media Server (managed via Docker)";
    
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
