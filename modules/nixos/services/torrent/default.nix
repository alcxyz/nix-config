# modules/nixos/services/torrent/default.nix
{
  config,
  lib,
  pkgs,
  username,
  ...
}: let
  cfg = config.services.torrent;
  serviceUser = "rtorrent";
  serviceGroup = "rtorrent";
  sharedGroup = "media";
  qbConfigDir = "/var/lib/qbittorrent";
  qbConfigStateDir = "${qbConfigDir}/profile";
  qbWebUiPort = 8080;
  qbTorrentingPort = 51413;
  qbWebUiTrustedClients = [
    "10.42.0.0/16"
    "192.168.1.10"
    "192.168.1.13"
    "192.168.1.15"
    "192.168.1.16"
    "192.168.1.23"
    "192.168.1.24"
  ];
  qbWebUiTrustedClientsCsv = lib.concatStringsSep "," qbWebUiTrustedClients;
  qbWebUiFirewallRules =
    lib.concatMapStringsSep "\n" (ip: ''
      iptables -A nixos-fw -p tcp --dport ${toString qbWebUiPort} -s ${ip} -j nixos-fw-accept
    '')
    qbWebUiTrustedClients;
  dataDir = "/tank/downloads";

  stashDir = "/tank/stash";
  mediaDir = "/tank/media";

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
    {
      path = dataDir;
      owner = serviceUser;
    }
    {
      path = dataDir + "/watch";
      owner = serviceUser;
    }
    {
      path = dataDir + "/completed";
      owner = serviceUser;
    }
    {
      path = stashDir;
      owner = "root";
    }
    {
      path = mediaDir;
      owner = "root";
    }
  ];
  sharedMediaRoots = [
    {
      path = stashDir;
      owner = "root";
    }
    {
      path = mediaDir;
      owner = "-";
    }
  ];

  sharedMediaDatasets = cfg.zfsDatasets;
  storageDependencyUnits = cfg.storageDependencyUnits;

  tmpfilesRules =
    map (d: "d " + d + " 0755 " + serviceUser + " " + serviceGroup + " -") torrentDirs
    ++ map (d: "d " + d + " 2775 " + serviceUser + " " + sharedGroup + " -") downloadDirs
    ++ map (d: "d " + d.path + " 2775 " + d.owner + " " + sharedGroup + " -") sharedMediaRoots
    ++ map (d: "z " + d.path + " 2775 " + d.owner + " " + sharedGroup + " - -") sharedMediaDirs
    ++ map (
      d: "a+ " + d.path + " - - - - g:" + sharedGroup + ":rwx,d:g:" + sharedGroup + ":rwx,m::rwx,d:m::rwx"
    )
    sharedMediaDirs;
in {
  options.services.torrent = {
    enable = lib.mkEnableOption "Torrent infrastructure (users and shared media directories)";

    zfsDatasets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "tank/downloads"
        "tank/stash"
        "tank/media"
      ];
      description = "ZFS datasets whose ACL properties should be enforced for shared torrent storage.";
    };

    storageDependencyUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "zfs-auto-unlock.service"
        "zfs-mount.service"
      ];
      description = "Storage services that must complete before torrent storage permissions are applied.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${sharedGroup} = {};
    users.groups.${serviceGroup} = {};
    users.users.${serviceUser} = {
      isSystemUser = true;
      group = serviceGroup;
      extraGroups = [
        sharedGroup
      ];
      createHome = true;
      home = qbConfigDir;
    };
    users.users.${username}.extraGroups = [serviceGroup];

    users.groups.flood = {};
    users.users.flood = {
      isSystemUser = true;
      group = "flood";
      extraGroups = [
        sharedGroup
      ];
    };

    systemd.tmpfiles.rules = tmpfilesRules;

    networking.firewall = {
      allowedTCPPorts = [
        qbTorrentingPort
      ];
      allowedUDPPorts = [qbTorrentingPort];
      extraCommands = qbWebUiFirewallRules;
    };

    services.qbittorrent = {
      enable = true;
      user = serviceUser;
      group = sharedGroup;
      profileDir = qbConfigStateDir;
      webuiPort = qbWebUiPort;
      torrentingPort = qbTorrentingPort;
    };

    systemd.services.qbittorrent = {
      unitConfig.RequiresMountsFor = map (directory: directory.path) sharedMediaDirs;
      requires = storageDependencyUnits ++ ["torrent-shared-media-permissions.service"];
      after = storageDependencyUnits ++ ["torrent-shared-media-permissions.service"];
      conflicts = ["docker-qbittorrent.service"];
      path = [
        pkgs.coreutils
        pkgs.crudini
      ];
      preStart = ''
        conf=${lib.escapeShellArg "${qbConfigStateDir}/qBittorrent/config/qBittorrent.conf"}
        mkdir -p "$(dirname "$conf")"
        touch "$conf"
        chmod 0600 "$conf"

        crudini --set "$conf" Preferences 'WebUI\AuthSubnetWhitelistEnabled' true
        crudini --set "$conf" Preferences 'WebUI\AuthSubnetWhitelist' ${lib.escapeShellArg qbWebUiTrustedClientsCsv}
        crudini --set "$conf" Preferences 'WebUI\LocalHostAuth' false
        crudini --set "$conf" Preferences 'WebUI\ReverseProxySupportEnabled' false
        crudini --set "$conf" Preferences 'WebUI\UseUPnP' false
      '';
      serviceConfig = {
        PrivateUsers = lib.mkForce false;
        SupplementaryGroups = [
          serviceGroup
        ];
      };
    };

    systemd.services.torrent-shared-media-zfs-properties = {
      description = "Enable POSIX ACLs on shared media ZFS datasets";
      wantedBy = ["multi-user.target"];
      requires = storageDependencyUnits;
      after = storageDependencyUnits;
      before = [
        "torrent-shared-media-permissions.service"
        "docker.service"
        "k3s.service"
      ];
      path = with pkgs; [
        zfs
        util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        # Several consumers require this prerequisite during boot. Keep the
        # successful result active so concurrent consumers do not repeatedly
        # start the same oneshot and exhaust its start limit.
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        datasets=(
          ${lib.concatMapStringsSep "\n          " lib.escapeShellArg sharedMediaDatasets}
        )
        mountpoints=(
          ${lib.concatMapStringsSep "\n          " (d: lib.escapeShellArg d.path) sharedMediaDirs}
        )

        for dataset in "''${datasets[@]}"; do
          if zfs list -H "$dataset" >/dev/null 2>&1; then
            zfs set acltype=posixacl "$dataset"
          fi
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
      unitConfig.RequiresMountsFor = map (directory: directory.path) sharedMediaDirs;
      wantedBy = ["multi-user.target"];
      requires = storageDependencyUnits ++ ["torrent-shared-media-zfs-properties.service"];
      after = storageDependencyUnits ++ ["torrent-shared-media-zfs-properties.service"];
      before = [
        "docker.service"
        "k3s.service"
        "plex.service"
        "qbittorrent.service"
        "stash.service"
      ];
      path = with pkgs; [
        acl
        coreutils
        findutils
      ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "torrent-shared-media";
        # This is a prerequisite for several long-running services. Preserve
        # the successful state instead of rerunning it for each consumer.
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        marker=/var/lib/torrent-shared-media/acl-v4
        dirs=(
          ${lib.concatMapStringsSep "\n          " (d: lib.escapeShellArg d.path) sharedMediaDirs}
        )

        for dir in "''${dirs[@]}"; do
          install -d -m 2775 -g ${lib.escapeShellArg sharedGroup} "$dir"
          chmod g+s "$dir"
          setfacl -m g:${lib.escapeShellArg sharedGroup}:rwx,d:g:${lib.escapeShellArg sharedGroup}:rwx,m::rwx,d:m::rwx "$dir"
        done

        chown ${lib.escapeShellArg serviceUser}:${lib.escapeShellArg sharedGroup} \
          ${lib.escapeShellArg dataDir} \
          ${lib.escapeShellArg (dataDir + "/watch")} \
          ${lib.escapeShellArg (dataDir + "/completed")}
        chown ${lib.escapeShellArg "root"}:${lib.escapeShellArg sharedGroup} \
          ${lib.escapeShellArg stashDir}
        chown ${lib.escapeShellArg "root"}:${lib.escapeShellArg sharedGroup} \
          ${lib.escapeShellArg mediaDir}

        if [[ ! -e "$marker" ]]; then
          for dir in "''${dirs[@]}"; do
            chgrp -R ${lib.escapeShellArg sharedGroup} "$dir"
            setfacl -R -m g:${lib.escapeShellArg sharedGroup}:rwX,d:g:${lib.escapeShellArg sharedGroup}:rwX,m::rwX,d:m::rwX "$dir"
            find "$dir" -type d -exec chmod g+s {} +
          done
          touch "$marker"
        fi
      '';
    };
  };
}
