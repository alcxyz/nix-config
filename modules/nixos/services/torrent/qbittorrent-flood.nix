# modules/nixos/services/torrent/qbittorrent-flood.nix
{ config, lib, pkgs, hostName, username, ... }:

with lib;

let
  svc          = config.services.torrent;
  uid          = svc.uid or 986;
  gid          = svc.gid or 980;
  mediaGid     = svc.mediaGid or 983;
  serviceUser  = svc.serviceUser or "rtorrent";
  serviceGroup = svc.serviceGroup or "rtorrent";
  qbConfigDir  = svc.qbittorrentConfigDir or "/var/lib/qbittorrent";
  dataDir      = svc.dataDir or "/zpool/downloads";
  extraShares  = svc.extraShares or [];

  # Ports used in the setup:
  #
  # - qbWebUIPort: qbittorrent-nox built-in web UI port. You can use this
  #   to interact directly with qbittorrent-nox if needed. (Default: 8080)
  # - floodPort: Flood's web interface port. (Default: 8112)
  # - torrentPort: The port used for bittorrent protocol connections. (Default: 51413)
  qbWebUIPort  = svc.qbWebUIPort or 8080;
  floodPort    = svc.floodPort or 8112;
  torrentPort  = svc.torrentPort or 51413;

  # Optional: Generate tmpfiles rules for any extra share directories.
  extraShareRules =
    map (share: "d " + share.hostPath + " 0755 " + serviceUser + " " +
                  serviceGroup + " -") extraShares;
in {
  options.services.torrent = {
    enable = mkEnableOption "Torrent services (qbittorrent-nox + Flood)";

    uid = mkOption {
      type = types.int;
      default = 986;
      description = "UID for the torrent service (qbittorrent‑nox).";
    };

    gid = mkOption {
      type = types.int;
      default = 980;
      description = "GID for the torrent service (qbittorrent‑nox).";
    };

    mediaGid = mkOption {
      type = types.int;
      default = 983;
      description = "GID of the host's media group.";
    };

    serviceUser = mkOption {
      type = types.str;
      default = "rtorrent";
      description =
        "Name of the dedicated service user for torrent services (used by both qbittorrent‑nox and Flood).";
    };

    serviceGroup = mkOption {
      type = types.str;
      default = "rtorrent";
      description = "Name of the group for torrent services.";
    };

    qbittorrentConfigDir = mkOption {
      type = types.str;
      default = "/var/lib/qbittorrent";
      description =
        "Directory to store qbittorrent‑nox configuration and runtime data.";
    };

    dataDir = mkOption {
      type = types.str;
      default = "/zpool/downloads";
      description =
        "Directory where qbittorrent‑nox saves torrent downloads.";
    };

    extraShares = mkOption {
      type = types.listOf (types.attrsOf types.str);
      default = [];
      description =
        "Extra share mount points. Each element should provide keys 'hostPath' and 'containerPath'.";
    };

    qbWebUIPort = mkOption {
      type = types.int;
      default = 8080;
      description =
        "Port at which qbittorrent‑nox's built‑in web UI is exposed.";
    };

    floodPort = mkOption {
      type = types.int;
      default = 8112;
      description =
        "Port at which Flood's web interface is exposed.";
    };

    torrentPort = mkOption {
      type = types.int;
      default = 51413;
      description =
        "Port for torrent protocol traffic (incoming connections for qbittorrent‑nox).";
    };
  };

  config = mkIf config.services.torrent.enable {
    ######################################################################
    # Install Necessary Packages
    ######################################################################
    environment.systemPackages = with pkgs; [
      qbittorrent-nox
      qbittorrent-cli
    ];

    ######################################################################
    # User and Group Setup
    ######################################################################
    users.groups.${serviceGroup} = { gid = gid; };

    users.users.${serviceUser} = {
      isSystemUser = true;
      uid = uid;
      group = serviceGroup;
      extraGroups = [ "media" ];
      createHome = true;
      home = qbConfigDir;
    };

    # Optionally, add your primary user to the torrent service group.
    users.users.${username}.extraGroups =
      mkIf (username != serviceUser) [ serviceGroup ];

    ######################################################################
    # Set Up Directories via tmpfiles
    ######################################################################
    systemd.tmpfiles.rules =
      [
        # qbittorrent configuration directory.
        "d " + qbConfigDir + " 0755 " + serviceUser + " " + serviceGroup + " -"
        # Download directory and its subdirectories.
        "d " + dataDir + " 0755 " + serviceUser + " " + serviceGroup + " -"
        "d " + dataDir + "/watch 0755 " + serviceUser + " " + serviceGroup + " -"
        "d " + dataDir + "/completed 0755 " + serviceUser + " " + serviceGroup + " -"
      ]
      ++ extraShareRules;

    ######################################################################
    # qbittorrent-nox Service
    #
    # qbittorrent‑nox will run with its built‑in web UI bound to qbWebUIPort
    # (default: 8080) and its torrent port set to torrentPort.
    #
    # Flood will then connect to qbittorrent‑nox on qbWebUIPort.
    ######################################################################
    systemd.services.qbittorrent-nox = {
      description = "qBittorrent-nox torrent engine";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart =
          "${pkgs.qbittorrent-nox}/bin/qbittorrent-nox " +
          "--webui-port=" + toString qbWebUIPort +
          " --profile=" + qbConfigDir +
          " --connection-port=" + toString torrentPort;
        User = serviceUser;
        Group = serviceGroup;
        Restart = "on-failure";
      };
      install = {
        WantedBy = [ "multi-user.target" ];
      };
    };

    ######################################################################
    # Flood Service Setup
    #
    # Flood is configured to connect to qbittorrent-nox at 127.0.0.1 on qbWebUIPort.
    # Its own external UI is bound to floodPort.
    ######################################################################
    services.flood.enable = true;
    services.flood.package = pkgs.flood;
    services.flood.port = floodPort;
    services.flood.host = "127.0.0.1";
    services.flood.extraArgs =
      "--torrentProvider=qbittorrent --torrentHost=127.0.0.1 --torrentPort=" +
      toString qbWebUIPort;

    # Ensure Flood starts after qbittorrent‑nox.
    systemd.services.flood.after = [ "qbittorrent-nox.service" ];

    ######################################################################
    # Firewall and Traefik Configuration
    #
    # Allow access to the torrent port (for inbound BT connections),
    # qbittorrent-nox's web UI (qbWebUIPort) and Flood's UI (floodPort).
    ######################################################################
    networking.firewall.allowedTCPPorts =
      mkIf (config.services.flood.openFirewall or false)
        [ floodPort qbWebUIPort torrentPort ];
    networking.firewall.allowedUDPPorts =
      mkIf (config.services.flood.openFirewall or false)
        [ torrentPort ];

    services.traefik.dynamicConfigOptions.http.routers.flood = {
      rule = "Host(`flood.${hostName}.local`)";
      entryPoints = [ "websecure" ];
      service = "flood";
      tls = true;
    };
    services.traefik.dynamicConfigOptions.http.services.flood = {
      loadBalancer.servers = [ { url = "http://127.0.0.1:" + toString floodPort; } ];
    };
  };
}
