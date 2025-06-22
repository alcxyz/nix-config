{ config, lib, pkgs, hostName, username, ... }:

with lib;

let
  # Fallback/default values for our options.
  serviceUser  = config.services.torrent.serviceUser or "rtorrent";
  serviceGroup = config.services.torrent.serviceGroup or "rtorrent";
  uid          = config.services.torrent.uid or 1001;
  gid          = config.services.torrent.gid or 1001;
  configDir    = config.services.torrent.configDir or "/var/lib/rtorrent";
  dataDir      = config.services.torrent.dataDir or "/zpool/downloads";
  extraShares  = config.services.torrent.extraShares or [];

  # Build extra volume mappings for the docker-compose file.
  extraVolumesLines = lib.concatStringsSep "\n" (map (share:
    "          - \"" + share.hostPath + ":" + share.containerPath + "\""
  ) extraShares);

  # Generate a simple rTorrent configuration file.
  rtorrentRc = pkgs.writeText "rtorrent.rc" ''
    ## Listening port – rTorrent binds internally to 6881.
    network.port_range.set=6881-6881

    ## Run rTorrent as a daemon.
    system.daemon.set=true

    ## Download directory (mounted to /data in the container).
    directory.default.set=/data

    ## Session directory – placed under $HOME/.local/share/rtorrent.
    session.path.set=/config/.local/share/rtorrent

    ## Expose the SCGI interface via Unix socket
    scgi_port = /config/.local/share/rtorrent/rtorrent.sock

    ## Watch directory for torrents.
    schedule2 = watch_directory, 5, 5, "load.start=/data/watch/*.torrent"

    ## Move completed downloads.
    method.insert = d.get_finished_dir, simple, "cat=/data/completed/,$d.name="
    method.insert = d.move_to_complete, simple, "d.directory.set=$argument.1=; execute=mkdir,-p,$argument.1=; execute=mv,-u,$argument.0=,$argument.1=; d.save_full_session="
    method.set_key = event.download.finished,move_complete,"d.move_to_complete=$d.data_path=,$d.get_finished_dir="
  '';

  # Create a script that sets up the configuration file and required directories.
  setupRtorrentConfigScript = pkgs.writeShellScript "setup-rtorrent-config" ''
    #!${pkgs.runtimeShell}
    ${pkgs.coreutils}/bin/mkdir -p ${configDir} &&
    ${pkgs.coreutils}/bin/mkdir -p ${configDir}/.local/share/rtorrent &&
    ${pkgs.coreutils}/bin/cp ${rtorrentRc} ${configDir}/.rtorrent.rc &&
    ${pkgs.coreutils}/bin/chown -R ${serviceUser}:${serviceGroup} ${configDir} &&
    ${pkgs.coreutils}/bin/chmod 0644 ${configDir}/.rtorrent.rc
  '';

  # Generate the Docker Compose file.
  dockerComposeFile = pkgs.writeText "docker-compose.yml" ''
    version: '3'
    services:
      rtorrent:
        image: jesec/rtorrent:latest
        container_name: rtorrent
        hostname: rtorrent
        user: "${toString uid}:${toString gid}"
        environment:
          HOME: /config
        volumes:
          - "${configDir}:/config"
          - "${dataDir}:/data"
${if extraVolumesLines == "" then "" else "\n" + extraVolumesLines}
        ports:
          - "0.0.0.0:51413:6881"
        restart: unless-stopped
        stop_grace_period: 1m

      flood:
        image: jesec/flood:latest
        container_name: flood
        hostname: flood
        user: "${toString uid}:${toString gid}"
        environment:
          HOME: /config
        volumes:
          - "${configDir}:/config"
          - "${dataDir}:/data"
${if extraVolumesLines == "" then "" else "\n" + extraVolumesLines}
        ports:
          - "127.0.0.1:8112:3000"
        command: --port 3000 --allowedpath /data
        restart: unless-stopped
        depends_on:
          - rtorrent
  '';

  # A start script that calls docker-compose.
  startScript = pkgs.writeShellScript "torrent-start" ''
    #!${pkgs.runtimeShell}
    ${pkgs.docker-compose}/bin/docker-compose -f ${dockerComposeFile} up -d
  '';
in {
  options.services.torrent = {
    enable = mkEnableOption "Torrent services (rTorrent + Flood via docker-compose)";
    uid = mkOption {
      type = types.int;
      default = 1001;
      description = "UID used for the container and file ownership.";
    };
    gid = mkOption {
      type = types.int;
      default = 1001;
      description = "GID used for the container and file ownership.";
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
      default = "/var/lib/rtorrent-config";
      description = "Directory for the rtorrent configuration file and session data.";
    };
    dataDir = mkOption {
      type = types.str;
      default = "/zpool/downloads";
      description = "Directory for torrent downloads.";
    };
    extraShares = mkOption {
      type = types.listOf (types.attrsOf types.str);
      default = [];
      description = "A list of extra share mount points. Each element should be an attribute set with keys 'hostPath' and 'containerPath'.";
    };
  };

  config = mkIf config.services.torrent.enable {
    virtualisation.docker.enable = true;
    environment.systemPackages = with pkgs; [ docker-compose ];

    ##########################
    # Create Service User and Group
    ##########################
    users.groups.${serviceGroup} = { gid = gid; };
    users.users.${serviceUser} = {
      isSystemUser = true;
      uid = uid;
      group = serviceGroup;
      createHome = true;
      home = configDir;
    };
    users.users.${username}.extraGroups = [ serviceGroup ];

    ##########################
    # Create Directories via tmpfiles
    ##########################
    systemd.tmpfiles.rules = [
      "d ${configDir} 0755 ${serviceUser} ${serviceGroup} -"
      "d ${configDir}/.local/share/rtorrent 0755 ${serviceUser} ${serviceGroup} -"
      "d ${dataDir} 0755 ${serviceUser} ${serviceGroup} -"
      "d ${dataDir}/watch 0755 ${serviceUser} ${serviceGroup} -"
      "d ${dataDir}/completed 0755 ${serviceUser} ${serviceGroup} -"
    ];

    ##########################
    # Setup the Custom Configuration File
    ##########################
    systemd.services.setup-rtorrent-config = {
      description = "Setup rtorrent configuration file in ${configDir}";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${setupRtorrentConfigScript}";
      };
    };

    ##########################
    # Docker Compose Service
    ##########################
    systemd.services.torrent = {
      description = "rTorrent & Flood via docker-compose";
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

    ##########################
    # Firewall and Traefik
    ##########################
    networking.firewall.allowedTCPPorts = [ 51413 8112 ];
    networking.firewall.allowedUDPPorts = [ 51413 6881 ];
    services.traefik.dynamicConfigOptions.http.routers.flood = {
      rule = "Host(`flood.${hostName}.local`)";
      entryPoints = [ "websecure" ];
      service = "flood";
      tls = true;
    };
    services.traefik.dynamicConfigOptions.http.services.flood = {
      loadBalancer.servers = [ { url = "http://127.0.0.1:8112"; } ];
    };
  };
}
