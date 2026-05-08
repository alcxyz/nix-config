# modules/nixos/services/stash/default.nix
{
  config,
  lib,
  pkgs,
  username,
  ...
}:

with lib;

let
  cfg = config.services.stash.managed;
in
{
  options.services.stash.managed = {
    enable = mkEnableOption "Stash (managed as a Docker container)";

    user = mkOption {
      type = types.str;
      default = "stash";
      description = "User for Stash file ownership.";
    };
    group = mkOption {
      type = types.str;
      default = "stash";
      description = "Group for Stash file ownership.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/stash";
      description = "Directory for Stash data (config, database, etc.).";
    };
    mediaDir = mkOption {
      type = types.path;
      default = "/zpool/stash";
      description = "Directory where Stash media is located.";
    };
  };

  config = mkIf cfg.enable {
    virtualisation.oci-containers.backend = "docker";

    users.groups.media = { };
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      extraGroups = [
        "media"
        "rtorrent"
      ];
    };
    users.groups.${cfg.group} = { };

    users.users.${username}.extraGroups = [ cfg.group ];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/config 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/metadata 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/cache 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/blobs 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/generated 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.mediaDir} 2775 - media - -"
      "a+ ${cfg.mediaDir} - - - - g:media:rwx,d:g:media:rwx,m::rwx,d:m::rwx"
    ];

    networking.firewall.allowedTCPPorts = [ 9999 ];

    virtualisation.oci-containers.containers.stash = {
      image = "nerethos/stash:latest";
      pull = "always";
      ports = [ "9999:9999/tcp" ];
      environment = {
        PUID = "989";
        PGID = "984";
        STASH_GENERATED = "/generated/";
        STASH_METADATA = "/metadata/";
        STASH_CACHE = "/cache/";
        NVIDIA_VISIBLE_DEVICES = "all";
        NVIDIA_DRIVER_CAPABILITIES = "compute,video,utility";
      };
      devices = [ "nvidia.com/gpu=all" ];
      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "/ypool/stash:/ypool/stash"
        "/zpool/stash:/zpool/stash"
        "${cfg.dataDir}/config:/root/.stash"
        "${cfg.dataDir}/metadata:/metadata"
        "${cfg.dataDir}/cache:/cache"
        "${cfg.dataDir}/generated:/generated"
        "${cfg.dataDir}/blobs:/blobs"
      ];
      log-driver = "json-file";
      extraOptions = [
        "--group-add=983"
        "--log-opt=max-file=10"
        "--log-opt=max-size=2m"
      ];
    };

    systemd.services.docker-stash = {
      requires = [
        "zfs-mount.service"
        "torrent-shared-media-permissions.service"
      ];
      after = [
        "zfs-mount.service"
        "torrent-shared-media-permissions.service"
      ];
    };
  };
}
