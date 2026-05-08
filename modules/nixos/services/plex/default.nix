{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.plex.managed;
  nativeDataDir = "${cfg.dataDir}/Library/Application Support";
in
{
  options.services.plex.managed = {
    enable = mkEnableOption "Plex Media Server managed as a native systemd service";

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
    users.groups.media = { };
    users.users.media = {
      isSystemUser = true;
      group = "media";
    };

    services.plex = {
      enable = true;
      dataDir = nativeDataDir;
      user = "media";
      group = "media";
      openFirewall = true;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0770 media media - -"
      "d ${nativeDataDir} 0770 media media - -"
      "d ${cfg.transcodeDir} 0770 media media - -"
      "d ${cfg.mediaDir} 0770 root media - -"
    ];

    systemd.services.plex = {
      requires = [
        "zfs-mount.service"
        "torrent-shared-media-permissions.service"
      ];
      after = [
        "zfs-mount.service"
        "torrent-shared-media-permissions.service"
      ];
      conflicts = [ "docker-plex.service" ];
      environment = {
        LD_LIBRARY_PATH = mkForce "";
        PLEX_MEDIA_SERVER_TMPDIR = mkForce cfg.transcodeDir;
      };
      serviceConfig = {
        BindReadOnlyPaths = [ "${cfg.mediaDir}:/media" ];
        BindPaths = [ "${cfg.transcodeDir}:/transcode" ];
      };
    };
  };
}
