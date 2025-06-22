{ config, lib, pkgs, hostName, username, ... }:

with lib;

let
  # Retrieve our options, providing sensible defaults.
  serviceUser  = config.services.torrent.serviceUser or "rtorrent";
  serviceGroup = config.services.torrent.serviceGroup or "rtorrent";
  uid          = config.services.torrent.uid or 986;
  gid          = config.services.torrent.gid or 980;
  configDir    = config.services.torrent.configDir or "/var/lib/rtorrent";
  dataDir      = config.services.torrent.dataDir or "/zpool/downloads";
  extraShares  = config.services.torrent.extraShares or [];

  # Build extra volume mapping lines (each extra share will be added to the volumes list).
  extraVolumesLines = lib.concatStringsSep "\n" (map (share:
    "          - \"" + share.hostPath + ":" + share.containerPath + "\""
  ) extraShares);

  # Generate a basic rTorrent configuration file.
  # Note: Flood does not accept arguments to pass to rTorrent, so we must use a .rtorrent.rc.
  # We specify the session directory relative to $HOME (which will be /config inside the container).
  rtorrentRc = pkgs.writeText "rtorrent.rc" ''
    ## Listening port – rTorrent binds internally to 6881.
    network.port_range.set=6881-6881

    ## Run rTorrent as a daemon.
    system.daemon.set=true

    ## Download directory: rTorrent will save files to /data.
    directory.default.set=/data

    ## Session directory: placed in $HOME/.local/share/rtorrent; with HOME=/config, this becomes /config/.local/share/rtorrent.
    session.path.set=/config/.local/share/rtorrent

    ## Expose the SCGI interface via Unix socket.
    network.scgi.open_local = /config/.local/share/rtorrent/rtorrent.sock

    ## Watch directory for torrents.
    schedule2 = watch_directory, 5, 5, "load.start=/data/watch/*.torrent"

    ## Move completed downloads.
    method.insert = d.get_finished_dir, simple, "cat=/data/completed/,$d.name="
    method.insert = d.move_to_complete, simple, "d.directory.set=$argument.1=; execute=mkdir,-p,$argument.1=; execute=mv,-u,$argument.0=,$argument.1=; d.save_full_session="
    method.set_key = event.download.finished,move_complete,"d.move_to_complete=$d.data_path=,$d.get_finished_dir="
  '';

  # A shell script that creates the configuration directory (if it does not exist),
  # creates the necessary subdirectory for session data, and copies the generated .rtorrent.rc file.
  setupRtorrentConfigScript = pkgs.writeShellScript "setup-rtorrent-config" ''
    #!${pkgs.runtimeShell}
    ${pkgs.coreutils}/bin/mkdir -p ${configDir} &&
    ${pkgs.coreutils}/bin/mkdir -p ${configDir}/.local/share/rtorrent &&
    ${pkgs.coreutils}/bin/cp ${rtorrentRc} ${configDir}/.rtorrent.rc &&
    ${pkgs.coreutils}/bin/chown -R ${serviceUser}:${serviceGroup} ${configDir} &&
    ${pkgs.coreutils}/bin/chmod 0644 ${configDir}/.rtorrent.rc
  '';

  # Generate the Docker Compose file for a single container running jesec/rtorrent-flood.
  dockerComposeFile = pkgs.writeText "docker-compose.yml" ''
    version: '3'
    services:
      rtorrent-flood:
        image: jesec/rtorrent-flood:latest
        container_name: rtorrent-flood
        hostname: rtorrent-flood
        user: "${toString uid}:${toString gid}"
        group_add: 
          - "983"
        environment:
          HOME: /config
        volumes:
          - "${configDir}:/config"
          - "${dataDir}:/data"
${if extraVolumesLines == "" then "" else "\n" + extraVolumesLines}
        ports:
          - "127.0.0.1:8112:3001"
          - "0.0.0.0:51413:6881"
        command: --port 3001 --allowedpath /data
        restart: unless-stopped
        stop_grace_period: 1m
  '';

  # A simple shell script that calls docker-compose.
  startScript = pkgs.writeShellScript "torrent-start" ''
    #!${pkgs.runtimeShell}
    ${pkgs.docker-compose}/bin/docker-compose -f ${dockerComposeFile} up -d
  '';
in {
  options.services.torrent = {
    enable = mkEnableOption "Torrent services (rTorrent-Flood single container)";
    uid = mkOption {
      type = types.int;
      default = 1000;
      description = "UID to run the container and for file ownership.";
    };
    gid = mkOption {
      type = types.int;
      default = 1001;
      description = "GID to run the container and for file ownership.";
    };
    serviceUser = mkOption {
      type = types.str;
      default = "rtorrent";
      description = "Name of the dedicated service user.";
    };
    serviceGroup = mkOption {
      type = types.str;
      default = "rtorrent";
      description = "Name of the dedicated service group.";
    };
    configDir = mkOption {
      type = types.str;
      default = "/home/jc/dlconfig";
      description = "Host directory for the rTorrent configuration file and session data (mounted as /config in the container).";
    };
    dataDir = mkOption {
      type = types.str;
      default = "/mnt/data0";
      description = "Host directory for torrent downloads (mounted as /data in the container).";
    };
    extraShares = mkOption {
      type = types.listOf (types.attrsOf types.str);
      default = [];
      description = "A list of extra share mount points. Each element should contain keys 'hostPath' and 'containerPath'.";
    };
  };

  config = mkIf config.services.torrent.enable {
    virtualisation.docker.enable = true;
    environment.systemPackages = with pkgs; [ docker-compose ];

    ##############################
    # Create Service User and Group
    ##############################
    users.groups.${serviceGroup} = { gid = gid; };
    users.users.${serviceUser} = {
      isSystemUser = true;
      uid = uid;
      group = serviceGroup;
      extraGroups = [ "media" ];
      createHome = true;
      home = configDir;
    };
    users.users.${username}.extraGroups = [ serviceGroup ];

    ##############################
    # Create Directories via tmpfiles
    ##############################
    systemd.tmpfiles.rules = [
      "d ${configDir} 0755 ${serviceUser} ${serviceGroup} -"
      "d ${configDir}/.local/share/rtorrent 0755 ${serviceUser} ${serviceGroup} -"
      "d ${dataDir} 0755 ${serviceUser} ${serviceGroup} -"
      "d ${dataDir}/watch 0755 ${serviceUser} ${serviceGroup} -"
      "d ${dataDir}/completed 0755 ${serviceUser} ${serviceGroup} -"
    ];

    ##############################
    # Setup rTorrent Configuration
    ##############################
    systemd.services.setup-rtorrent-config = {
      description = "Setup rTorrent configuration file in ${configDir}";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${setupRtorrentConfigScript}";
      };
    };

    ##############################
    # Docker Compose Service for Single Container
    ##############################
    systemd.services.torrent = {
      description = "rTorrent-Flood via docker-compose (single container)";
      after = [ "docker.service" "setup-rtorrent-config.service" ];
      requires = [ "docker.service" "setup-rtorrent-config.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${startScript}";
        ExecStop = "${pkgs.docker-compose}/bin/docker-compose -f ${dockerComposeFile} down";
      };
    };

    ##############################
    # Firewall and Traefik
    ##############################
    networking.firewall.allowedTCPPorts = [ 6881 3001 ];
    networking.firewall.allowedUDPPorts = [ 6881 3001 ];
    services.traefik.dynamicConfigOptions.http.routers.flood = {
      rule = "Host(`flood.${hostName}.local`)";
      entryPoints = [ "websecure" ];
      service = "rtorrent-flood";
      tls = true;
    };
    services.traefik.dynamicConfigOptions.http.services.flood = {
      loadBalancer.servers = [ { url = "http://127.0.0.1:3001"; } ];
    };
  };
}
