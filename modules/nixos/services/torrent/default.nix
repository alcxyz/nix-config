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
  qbConfigDir = "/zpool/appdata/qbittorrent";
  qbConfigStateDir = "${qbConfigDir}/profile";
  qbNativeDir = "${qbConfigStateDir}/qBittorrent";
  qbLegacyDir = "/var/lib/qbittorrent/qBittorrent/qBittorrent";
  qbLegacyNativeDir = "/var/lib/qbittorrent/qBittorrent/qBittorrent";
  dataDir = "/zpool/downloads";

  stashDir = "/zpool/stash";
  stash2Dir = "/ypool/stash";
  mediaDir = "/ypool/media";

  torrentDirs = [
    qbConfigDir
    qbConfigStateDir
  ];

  downloadDirs = [
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
    "ypool/media"
  ];

  tmpfilesRules =
    map (d: "d " + d + " 0755 " + serviceUser + " " + serviceGroup + " -") torrentDirs
    ++ map (d: "d " + d + " 2775 " + serviceUser + " " + sharedGroup + " -") downloadDirs
    ++ map (d: "d " + d + " 2775 - " + sharedGroup + " -") sharedMediaDirs
    ++ map (
      d: "a+ " + d + " - - - - g:" + sharedGroup + ":rwx,d:g:" + sharedGroup + ":rwx,m::rwx,d:m::rwx"
    ) sharedMediaDirs;
  qbittorrentStateMigration = pkgs.writeShellScript "qbittorrent-state-migration" ''
    set -euo pipefail

    install -d -m 0755 -o ${lib.escapeShellArg serviceUser} -g ${lib.escapeShellArg sharedGroup} \
      ${lib.escapeShellArg (qbNativeDir + "/config")} \
      ${lib.escapeShellArg (qbNativeDir + "/data/BT_backup")}

    if [ -f ${lib.escapeShellArg (qbLegacyNativeDir + "/config/qBittorrent.conf")} ] \
      && ! grep -q 'WebUI\\Password_PBKDF2' ${
        lib.escapeShellArg (qbNativeDir + "/config/qBittorrent.conf")
      } 2>/dev/null; then
      cp -a ${lib.escapeShellArg (qbLegacyNativeDir + "/config/qBittorrent.conf")} ${
        lib.escapeShellArg (qbNativeDir + "/config/qBittorrent.conf")
      }
    elif [ -f ${lib.escapeShellArg (qbLegacyDir + "/qBittorrent.conf")} ] \
      && ! grep -q 'WebUI\\Password_PBKDF2' ${
        lib.escapeShellArg (qbNativeDir + "/config/qBittorrent.conf")
      } 2>/dev/null; then
      cp -a ${lib.escapeShellArg (qbLegacyDir + "/qBittorrent.conf")} ${
        lib.escapeShellArg (qbNativeDir + "/config/qBittorrent.conf")
      }
    fi

    if [ -f ${lib.escapeShellArg (qbLegacyNativeDir + "/config/qBittorrent-data.conf")} ]; then
      cp -a ${lib.escapeShellArg (qbLegacyNativeDir + "/config/qBittorrent-data.conf")} ${
        lib.escapeShellArg (qbNativeDir + "/config/qBittorrent-data.conf")
      }
    elif [ -f ${lib.escapeShellArg (qbLegacyDir + "/qBittorrent-data.conf")} ]; then
      cp -a ${lib.escapeShellArg (qbLegacyDir + "/qBittorrent-data.conf")} ${
        lib.escapeShellArg (qbNativeDir + "/config/qBittorrent-data.conf")
      }
    fi

    if [ -d ${lib.escapeShellArg (qbLegacyNativeDir + "/data/BT_backup")} ] \
      && [ -z "$(${pkgs.findutils}/bin/find ${
        lib.escapeShellArg (qbNativeDir + "/data/BT_backup")
      } -maxdepth 1 -name '*.fastresume' -print -quit)" ]; then
      cp -a ${lib.escapeShellArg (qbLegacyNativeDir + "/data/BT_backup/.")} ${
        lib.escapeShellArg (qbNativeDir + "/data/BT_backup/")
      }
    elif [ -d ${lib.escapeShellArg (qbLegacyDir + "/BT_backup")} ] \
      && [ -z "$(${pkgs.findutils}/bin/find ${
        lib.escapeShellArg (qbNativeDir + "/data/BT_backup")
      } -maxdepth 1 -name '*.fastresume' -print -quit)" ]; then
      cp -a ${lib.escapeShellArg (qbLegacyDir + "/BT_backup/.")} ${
        lib.escapeShellArg (qbNativeDir + "/data/BT_backup/")
      }
    fi

    chown -R ${lib.escapeShellArg serviceUser}:${lib.escapeShellArg sharedGroup} ${lib.escapeShellArg qbNativeDir}
  '';
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

    networking.firewall = {
      allowedTCPPorts = [
        8080
        51413
      ];
      allowedUDPPorts = [ 51413 ];
    };

    services.qbittorrent = {
      enable = true;
      user = serviceUser;
      group = sharedGroup;
      profileDir = qbConfigStateDir;
      webuiPort = 8080;
      torrentingPort = 51413;
    };

    systemd.services.qbittorrent = {
      requires = [
        "zfs-mount.service"
        "torrent-shared-media-permissions.service"
      ];
      after = [
        "zfs-mount.service"
        "torrent-shared-media-permissions.service"
      ];
      conflicts = [ "docker-qbittorrent.service" ];
      serviceConfig = {
        ExecStartPre = [ "+${qbittorrentStateMigration}" ];
        PrivateUsers = lib.mkForce false;
        SupplementaryGroups = [
          serviceGroup
          "stash"
        ];
      };
    };

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

  };
}
