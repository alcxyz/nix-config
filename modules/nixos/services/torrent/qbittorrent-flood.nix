# modules/nixos/services/torrent/qbittorrent-flood.nix
{ config, lib, pkgs, hostName, username, ... }:

let
  # --- Hardcoded Service Configuration Values ---
  serviceUser   = "rtorrent";
  serviceGroup  = "rtorrent";

  # Directories for qBittorrent configuration and primary downloads.
  qbConfigDir   = "/var/lib/qbittorrent";
  dataDir       = "/zpool/downloads"; # This is the base for all torrent-related files

  # Directories with legacy ownership
  stashDir      = "/zpool/stash";   # owned by stash:stash
  stash2Dir      = "/ypool/stash";   # owned by stash:stash
  mediaDir      = "/zpool/media";   # owned by media:media

  # Overlay mount points for qBittorrent operations, now under dataDir:
  stashOverlayDir = "${dataDir}/stash_rtorrent";
  stash2OverlayDir = "${dataDir}/stash2_rtorrent";
  mediaOverlayDir = "${dataDir}/media_rtorrent";

  # Ports for the services.
  qbWebUIPort   = 8080;  # qBittorrent-nox's built-in WebUI/API port.
  floodPort     = 8112;  # Flood’s own web interface port.
  torrentPort   = 51413; # BitTorrent incoming connections port.

  # Flood's connection details for the qBittorrent Web API.
  qbUrl         = "";    # If empty, defaults to http://127.0.0.1:<qbWebUIPort>.
  qbUser        = "";
  qbPass        = "";
  finalQbUrl    = if qbUrl == "" then "http://127.0.0.1:" + toString qbWebUIPort
                  else qbUrl;
  floodExtraArg1 = "--qburl=" + finalQbUrl;
  floodExtraArg2 = "--qbuser=" + qbUser;
  floodExtraArg3 = "--qbpass=" + qbPass;

  # List of directories to be ensured via systemd-tmpfiles.
  baseDirs = [
    qbConfigDir
    dataDir
    (dataDir + "/watch")
    (dataDir + "/completed")
    stashOverlayDir # Now includes the new location
    stash2OverlayDir # Now includes the new location
    mediaOverlayDir # Now includes the new location
  ];
  tmpfilesRules = map (d:
    "d " + d + " 0755 " + serviceUser + " " + serviceGroup + " -"
  ) baseDirs;
in {

  options.services.torrent.enable =
    lib.mkEnableOption "Torrent services (qbittorrent-nox + Flood)";

  config = lib.mkIf config.services.torrent.enable {

    ######################################################################
    # Install Necessary Packages
    ######################################################################
    environment.systemPackages = with pkgs; [
      qbittorrent-nox
      qbittorrent-cli
      flood
      bindfs
    ];

    ######################################################################
    # Set Up Service Users and Groups
    ######################################################################
    users.groups.${serviceGroup} = { };
    users.users.${serviceUser} = {
      isSystemUser = true;
      group = serviceGroup;
      extraGroups = [ "media" "stash" ];
      createHome = true;
      home = qbConfigDir;
    };
    users.users.${username}.extraGroups = [ serviceGroup ];

    users.groups.flood = { };
    users.users.flood = {
      isSystemUser = true;
      group = "flood";
      extraGroups = [ "media" "stash" ];
    };

    ######################################################################
    # Create Necessary Directories via systemd-tmpfiles.
    ######################################################################
    systemd.tmpfiles.rules = tmpfilesRules;

    ######################################################################
    # qBittorrent-nox Service Configuration
    ######################################################################
    systemd.services.qbittorrent-nox = {
      description = "qBittorrent-nox torrent engine";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = ''
          ${pkgs.qbittorrent-nox}/bin/qbittorrent-nox \
            --webui-port=${toString qbWebUIPort} \
            --torrenting-port=${toString torrentPort} \
            --profile=${qbConfigDir}
        '';
        User = serviceUser;
        Group = serviceGroup;
        Restart = "on-failure";
        UMask = "0002";
      };
      wantedBy = [ "multi-user.target" ];
    };

    ######################################################################
    # Flood Service Configuration
    ######################################################################
    services.flood.enable = true;
    services.flood.package = pkgs.flood;
    services.flood.port = floodPort;
    services.flood.host = "127.0.0.1";
    services.flood.extraArgs = [
      floodExtraArg1
      floodExtraArg2
      floodExtraArg3
    ];
    systemd.services.flood.after = [ "qbittorrent-nox.service" ];

    ######################################################################
    # Firewall and Traefik Proxy Configuration
    ######################################################################
    networking.firewall.allowedTCPPorts =
      [ floodPort qbWebUIPort torrentPort ];
    networking.firewall.allowedUDPPorts = [ torrentPort ];

    services.traefik.dynamicConfigOptions.http.routers.flood = {
      rule = "Host(`flood.${hostName}.local`)";
      entryPoints = [ "websecure" ];
      service = "flood";
      tls = true;
    };
    services.traefik.dynamicConfigOptions.http.services.flood = {
      loadBalancer.servers = [
        { url = "http://127.0.0.1:" + toString floodPort; }
      ];
    };

    ######################################################################
    # Bindfs Mounts for Overlaying Directories
      ######################################################################
    systemd.mounts = [
      {
        description =
          "Bind mount /zpool/stash to ${stashOverlayDir} with remapped ownership";
        what = stashDir;
        where = stashOverlayDir; # This is now under /zpool/downloads
        type = "fuse.bindfs";
        options =
          "force-user=" + serviceUser +
          ",force-group=" + serviceGroup +
          ",perms=770";
        wantedBy = [ "multi-user.target" ];
      }
      {
        description =
          "Bind mount /zpool/media to ${mediaOverlayDir} with remapped ownership";
        what = mediaDir;
        where = mediaOverlayDir; # This is now under /zpool/downloads
        type = "fuse.bindfs";
        options =
          "force-user=" + serviceUser +
          ",force-group=" + serviceGroup +
          ",perms=770";
        wantedBy = [ "multi-user.target" ];
      }
      {
        description =
          "Bind mount /ypool/stash2 to ${stash2OverlayDir} with remapped ownership";
        what = stash2Dir;
        where = stash2OverlayDir; # This is now under /zpool/downloads
        type = "fuse.bindfs";
        options =
          "force-user=" + serviceUser +
          ",force-group=" + serviceGroup +
          ",perms=770";
        wantedBy = [ "multi-user.target" ];
      }
    ];
  };
}
