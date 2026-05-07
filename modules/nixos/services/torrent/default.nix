# modules/nixos/services/torrent/default.nix
{
  config,
  lib,
  pkgs,
  username,
  ...
}:

let
  serviceUser = "rtorrent";
  serviceGroup = "rtorrent";
  sharedGroup = "media";
  qbConfigDir = "/var/lib/qbittorrent";
  qbConfigStateDir = "${qbConfigDir}/qBittorrent";
  dataDir = "/zpool/downloads";

  stashDir = "/zpool/stash";
  stash2Dir = "/ypool/stash";
  mediaDir = "/zpool/media";

  torrentDirs = [
    qbConfigDir
    qbConfigStateDir
    dataDir
    (dataDir + "/watch")
    (dataDir + "/completed")
  ];

  sharedMediaDirs = [
    stashDir
    stash2Dir
    mediaDir
  ];

  sharedMediaDatasets = [
    "zpool/stash"
    "ypool/stash"
    "zpool/media"
  ];

  tmpfilesRules =
    map (d: "d " + d + " 0755 " + serviceUser + " " + serviceGroup + " -") torrentDirs
    ++ map (d: "d " + d + " 2775 - " + sharedGroup + " -") sharedMediaDirs
    ++ map (
      d: "a+ " + d + " - - - - g:" + sharedGroup + ":rwx,d:g:" + sharedGroup + ":rwx,m::rwx,d:m::rwx"
    ) sharedMediaDirs;
in
{
  options.services.torrent.enable = lib.mkEnableOption "Torrent infrastructure (users and shared media directories)";

  config = lib.mkIf config.services.torrent.enable {
    users.groups.${sharedGroup} = { };
    users.groups.${serviceGroup} = { };
    users.users.${serviceUser} = {
      isSystemUser = true;
      group = serviceGroup;
      extraGroups = [
        sharedGroup
        "stash"
      ];
      createHome = true;
      home = qbConfigDir;
    };
    users.users.${username}.extraGroups = [ serviceGroup ];

    users.groups.flood = { };
    users.users.flood = {
      isSystemUser = true;
      group = "flood";
      extraGroups = [
        sharedGroup
        "stash"
      ];
    };

    systemd.tmpfiles.rules = tmpfilesRules;

    systemd.services.torrent-shared-media-zfs-properties = {
      description = "Enable POSIX ACLs on shared media ZFS datasets";
      wantedBy = [ "multi-user.target" ];
      requires = [ "zfs-auto-unlock.service" ];
      after = [ "zfs-auto-unlock.service" ];
      before = [
        "torrent-shared-media-permissions.service"
        "docker.service"
        "k3s.service"
      ];
      path = with pkgs; [
        zfs
        util-linux
      ];
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail

        datasets=(
          ${lib.concatMapStringsSep "\n          " lib.escapeShellArg sharedMediaDatasets}
        )
        mountpoints=(
          ${lib.concatMapStringsSep "\n          " lib.escapeShellArg sharedMediaDirs}
        )

        for dataset in "''${datasets[@]}"; do
          zfs set acltype=posixacl "$dataset"
        done

        for mountpoint in "''${mountpoints[@]}"; do
          if findmnt -no OPTIONS "$mountpoint" | tr ',' '\n' | grep -qx noacl; then
            mount -o remount,acl "$mountpoint" || true
          fi
        done
      '';
    };

    systemd.services.torrent-shared-media-permissions = {
      description = "Apply shared media ACLs for torrent and media workloads";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "zfs-mount.service"
        "torrent-shared-media-zfs-properties.service"
      ];
      after = [
        "zfs-mount.service"
        "torrent-shared-media-zfs-properties.service"
      ];
      before = [
        "docker.service"
        "k3s.service"
      ];
      path = with pkgs; [
        acl
        coreutils
        findutils
      ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "torrent-shared-media";
      };
      script = ''
        set -euo pipefail

        marker=/var/lib/torrent-shared-media/acl-v1
        dirs=(
          ${lib.escapeShellArg stashDir}
          ${lib.escapeShellArg stash2Dir}
          ${lib.escapeShellArg mediaDir}
        )

        for dir in "''${dirs[@]}"; do
          install -d -m 2775 -g ${lib.escapeShellArg sharedGroup} "$dir"
          chmod g+s "$dir"
          setfacl -m g:${lib.escapeShellArg sharedGroup}:rwx,d:g:${lib.escapeShellArg sharedGroup}:rwx,m::rwx,d:m::rwx "$dir"
        done

        if [[ ! -e "$marker" ]]; then
          for dir in "''${dirs[@]}"; do
            setfacl -R -m g:${lib.escapeShellArg sharedGroup}:rwX,d:g:${lib.escapeShellArg sharedGroup}:rwX,m::rwX,d:m::rwX "$dir"
            find "$dir" -type d -exec chmod g+s {} +
          done
          touch "$marker"
        fi
      '';
    };

    systemd.services.torrent-legacy-media-symlinks = {
      description = "Replace legacy qBittorrent bindfs mountpoints with symlinks";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "zfs-mount.service"
        "torrent-shared-media-permissions.service"
      ];
      after = [
        "zfs-mount.service"
        "torrent-shared-media-permissions.service"
      ];
      before = [
        "docker.service"
        "k3s.service"
      ];
      path = with pkgs; [
        coreutils
        util-linux
      ];
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail

        link_if_empty() {
          local link=$1
          local target=$2

          if mountpoint -q "$link"; then
            echo "$link is still a mountpoint; reboot after removing the old bindfs units before creating the compatibility symlink" >&2
            exit 1
          fi

          if [[ -L "$link" ]]; then
            ln -sfn "$target" "$link"
            return
          fi

          if [[ -e "$link" ]]; then
            rmdir "$link"
          fi

          ln -s "$target" "$link"
        }

        install -d -m 0755 -o ${lib.escapeShellArg serviceUser} -g ${lib.escapeShellArg serviceGroup} ${lib.escapeShellArg dataDir}
        link_if_empty ${lib.escapeShellArg (dataDir + "/stash_rtorrent")} ${lib.escapeShellArg stashDir}
        link_if_empty ${lib.escapeShellArg (dataDir + "/stash2_rtorrent")} ${lib.escapeShellArg stash2Dir}
        link_if_empty ${lib.escapeShellArg (dataDir + "/media_rtorrent")} ${lib.escapeShellArg mediaDir}
      '';
    };
  };
}
