# modules/nixos/services/torrent/qbittorrent-flood.nix
{ config, lib, pkgs, hostName, username, ... }:

# Define core configuration variables outside the module's 'let' block
# for maximum isolation from parsing quirks within options.
let
  # --- Hardcoded Service Configuration Values ---
  # These values are set here directly.

  # Torrent service user and group names.
  serviceUser      = "rtorrent";
  serviceGroup     = "rtorrent";

  # Directories for qBittorrent configuration and downloads.
  qbConfigDir      = "/var/lib/qbittorrent";
  dataDir          = "/zpool/downloads";

  # Ports for the services.
  qbWebUIPort      = 8080; # qBittorrent-nox's built-in WebUI/API port.
  floodPort        = 8112; # Flood’s own web interface port.
  torrentPort      = 51413; # Port for incoming BitTorrent connections.

  # Flood's connection details for the qBittorrent Web API.
  qbUrl            = "";   # If empty, defaults to http://127.0.0.1:<qbWebUIPort>.
  qbUser           = "";
  qbPass           = "";

  # Derived URL for Flood to connect to qBittorrent.
  finalQbUrl = if qbUrl == "" then "http://127.0.0.1:" + toString qbWebUIPort else qbUrl;

  # Define each Flood extra argument string as a completely separate variable.
  # This makes each string an unambiguous, pre-evaluated literal for the list.
  floodExtraArg1 = "--qburl=" + finalQbUrl;
  floodExtraArg2 = "--qbuser=" + qbUser;
  floodExtraArg3 = "--qbpass=" + qbPass;

  # List of directories to be created via systemd-tmpfiles.
  baseDirs = [ qbConfigDir dataDir (dataDir + "/watch") (dataDir + "/completed") ];
  tmpfilesRules = map (d: "d " + d + " 0755 " + serviceUser + " " + serviceGroup + " -") baseDirs;

in {
  # The only option exposed for this module: enable/disable the whole setup.
  options.services.torrent.enable = lib.mkEnableOption "Torrent services (qbittorrent-nox + Flood)";

  config = lib.mkIf config.services.torrent.enable {
    ######################################################################
    # Install Necessary Packages
    ######################################################################
    environment.systemPackages = with pkgs; [
      qbittorrent-nox
      qbittorrent-cli
      flood
    ];

    ######################################################################
    # Set Up Service Users and Groups
    ######################################################################
    # Define the service group for qBittorrent-nox.
    users.groups.${serviceGroup} = { };
    # Define the service user for qBittorrent-nox and add to 'media' group.
    users.users.${serviceUser} = {
      isSystemUser = true;
      group = serviceGroup;
      extraGroups = [ "media" "stash" ]; # Essential for accessing seeded files.
      createHome = true;
      home = qbConfigDir;
    };
    # Ensure your primary user (from configuration.nix) is in the torrent service group.
    users.users.${username}.extraGroups = [ serviceGroup ];

    # Define the Flood user (created by the Flood service) and add to 'media' group.
    users.groups.flood = { };
    users.users.flood = {
      isSystemUser = true;
      group = "flood";
      extraGroups = [ "media" "stash" ]; # Essential for accessing seeded files.
    };

    ######################################################################
    # Create Necessary Directories via systemd-tmpfiles.
    # Directories are created with specified ownership and permissions.
    ######################################################################
    systemd.tmpfiles.rules = tmpfilesRules;

    ######################################################################
    # qBittorrent-nox Service Configuration
    # This runs the headless qBittorrent client.
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
      };
      wantedBy = [ "multi-user.target" ];
    };

    ######################################################################
    # Flood Service Configuration
    # This runs the web UI that interfaces with qBittorrent-nox.
    ######################################################################
    services.flood.enable = true;
    services.flood.package = pkgs.flood;
    services.flood.port = floodPort;
    services.flood.host = "127.0.0.1";
    # Refer to the pre-defined argument variables.
    services.flood.extraArgs = [
      floodExtraArg1
      floodExtraArg2
      floodExtraArg3
    ];
    # Ensure Flood starts only after qBittorrent-nox is ready.
    systemd.services.flood.after = [ "qbittorrent-nox.service" ];

    ######################################################################
    # Firewall and Traefik Proxy Configuration
    # Ports are opened for torrenting, qBittorrent's API, and Flood's UI.
    ######################################################################
    # By default, open these ports as the module is designed to be a functional setup.
    networking.firewall.allowedTCPPorts = [ floodPort qbWebUIPort torrentPort ];
    networking.firewall.allowedUDPPorts = [ torrentPort ];

    services.traefik.dynamicConfigOptions.http.routers.flood = {
      rule = "Host(`flood.${hostName}.local`)";
      entryPoints = [ "websecure" ];
      service = "flood";
      tls = true;
    };
    services.traefik.dynamicConfigOptions.http.services.flood = {
      loadBalancer.servers =
        [ { url = "http://127.0.0.1:${toString floodPort}"; } ];
    };
  };
}
