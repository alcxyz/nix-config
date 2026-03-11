# modules/nixos/services/torrent/default.nix
{ config, lib, pkgs, username, ... }:

let
  serviceUser = "rtorrent";
  serviceGroup = "rtorrent";
  qbConfigDir = "/var/lib/qbittorrent";
  dataDir = "/zpool/downloads";

  stashDir = "/zpool/stash";
  stash2Dir = "/ypool/stash";
  mediaDir = "/zpool/media";

  stashOverlayDir = "${dataDir}/stash_rtorrent";
  stash2OverlayDir = "${dataDir}/stash2_rtorrent";
  mediaOverlayDir = "${dataDir}/media_rtorrent";

  baseDirs = [
    qbConfigDir
    dataDir
    (dataDir + "/watch")
    (dataDir + "/completed")
    stashOverlayDir
    stash2OverlayDir
    mediaOverlayDir
  ];

  tmpfilesRules = map (d:
    "d " + d + " 0755 " + serviceUser + " " + serviceGroup + " -"
  ) baseDirs;
in {
  options.services.torrent.enable =
    lib.mkEnableOption "Torrent infrastructure (users, dirs, mounts for Docker)";

  config = lib.mkIf config.services.torrent.enable {
    environment.systemPackages = with pkgs; [
      bindfs
    ];

    users.groups.${serviceGroup} = {};
    users.users.${serviceUser} = {
      isSystemUser = true;
      group = serviceGroup;
      extraGroups = [ "media" "stash" ];
      createHome = true;
      home = qbConfigDir;
    };
    users.users.${username}.extraGroups = [ serviceGroup ];

    users.groups.flood = {};
    users.users.flood = {
      isSystemUser = true;
      group = "flood";
      extraGroups = [ "media" "stash" ];
    };

    systemd.tmpfiles.rules = tmpfilesRules;

    systemd.mounts = [
      {
        description =
          "Bind mount /zpool/stash to ${stashOverlayDir} with remapped ownership";
        what = stashDir;
        where = stashOverlayDir;
        type = "fuse.bindfs";
        options =
          "force-user=${serviceUser},"
          + "force-group=${serviceGroup},"
          + "perms=770";
        requires = [ "zfs-mount.service" ];
        after = [ "zfs-mount.service" ];
        before = [ "docker.service" ];
        wantedBy = [ "multi-user.target" ];
        requiredBy = [ "docker.service" ];
      }
      {
        description =
          "Bind mount /zpool/media to ${mediaOverlayDir} with remapped ownership";
        what = mediaDir;
        where = mediaOverlayDir;
        type = "fuse.bindfs";
        options =
          "force-user=${serviceUser},"
          + "force-group=${serviceGroup},"
          + "perms=770";
        requires = [ "zfs-mount.service" ];
        after = [ "zfs-mount.service" ];
        before = [ "docker.service" ];
        wantedBy = [ "multi-user.target" ];
        requiredBy = [ "docker.service" ];
      }
      {
        description =
          "Bind mount /ypool/stash to ${stash2OverlayDir} with remapped ownership";
        what = stash2Dir;
        where = stash2OverlayDir;
        type = "fuse.bindfs";
        options =
          "force-user=${serviceUser},"
          + "force-group=${serviceGroup},"
          + "perms=770";
        requires = [ "zfs-mount.service" ];
        after = [ "zfs-mount.service" ];
        before = [ "docker.service" ];
        wantedBy = [ "multi-user.target" ];
        requiredBy = [ "docker.service" ];
      }
    ];
  };
}
