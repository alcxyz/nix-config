# modules/nixos/services/torrent/default.nix
{ config, pkgs, lib, username, ... }:

{
  # ====================================================================
  # 1. Enable Docker and Add User to Docker Group
  # ====================================================================
  virtualisation.docker.enable = true;
  users.users.${username}.extraGroups = [ "docker" ];

  # ====================================================================
  # 2. Manage Host Directories and Permissions
  # ====================================================================
  # This is a Nix list. Each string is an element, separated by spaces, NOT commas.
  systemd.tmpfiles.rules = [
    "d /var/lib/rtorrent 0775 ${username} media -"
    "d /zpool/downloads 0775 ${username} media -"
    "d /zpool/downloads/watch 0775 ${username} media -"
    # Create a self-contained .rtorrent.rc file to avoid permission errors from the default.
    "f /var/lib/rtorrent/.rtorrent.rc 0664 ${username} media - \"# Base directory for all torrent data (inside container).\ndirectory.default.set = /data/\n\n# Session directory where rTorrent stores its state (inside container).\nsession.path.set = /config/session/\n\n# Watch directory for new .torrent files.\nschedule = watch_directory,5,5,\\\"load.start=/data/watch/*.torrent\\\"\n\n# Enable DHT and set the port.\ndht.mode.set = auto\ndht.port.set = 6881\n\n# Enable Peer Exchange.\nprotocol.pex.set = 1\n\n# Set umask to ensure downloaded files are group-writable on the host.\nsystem.umask.set = 002\n\n# Enable encryption.\nprotocol.encryption.set = allow_incoming, try_outgoing, enable_retry\n\""
  ]; # <--- CORRECTED: NO COMMAS IN THIS LIST

  # ====================================================================
  # 3. Configure Firewall
  # ====================================================================
  networking.firewall = {
    allowedTCPPorts = [ 51413 ];
    allowedUDPPorts = [ 51413 ];
  };

  # ====================================================================
  # 4. Declaratively Create the Docker Compose File
  # ====================================================================
  environment.etc."docker-stacks/rtorrent-flood/docker-compose.yml".text = ''
    version: '3.8'
    services:
      rtorrent:
        image: jesec/rtorrent:latest
        container_name: rtorrent
        restart: unless-stopped
        # CRITICAL: Using your PUID:PGID
        user: "1000:983"
        volumes:
          - "/var/lib/rtorrent:/config"
          - "/zpool/downloads:/data"
        ports:
          - "51413:51413/tcp"
          - "51413:51413/udp"
        command:
          - "-o"
          - "network.port_range.set=51413-51413"
          - "-o"
          - "system.daemon.set=true"

      flood:
        image: jesec/flood:latest
        container_name: flood
        restart: unless-stopped
        # CRITICAL: Using your PUID:PGID
        user: "1000:983"
        volumes:
          - "/var/lib/rtorrent:/config"
          - "/zpool/downloads:/data"
        ports:
          - "8112:8112"
        environment:
          HOME: /config
        command:
          - "--port"
          - "8112"
          - "--allowedpath"
          - "/data"
        labels:
          traefik.enable: "true"
          traefik.http.routers.flood.rule: "Host(`deluge.xyz.local`)"
          traefik.http.routers.flood.entrypoints: "websecure"
          traefik.http.routers.flood.service: "flood"
          traefik.http.routers.flood.tls: "true"
          traefik.http.services.flood.loadbalancer.servers.0.url: "http://localhost:8112"
  '';

  # ====================================================================
  # 5. Create a systemd Service to Launch the Docker Compose Stack
  # ====================================================================
  systemd.services.rtorrent-flood-stack = {
    description = "rTorrent and Flood Docker Compose Stack";
    requires = [ "docker.service" ];
    after = [ "docker.service" "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      User = username;
      WorkingDirectory = "/etc/docker-stacks/rtorrent-flood";
      Type = "oneshot";
      RemainAfterExit = true;
      # The stop command belongs inside serviceConfig as ExecStop.
      ExecStop = "${pkgs.docker-compose}/bin/docker-compose down";
    };

    # The start command is defined by the 'script' attribute.
    script = ''
      ${pkgs.docker-compose}/bin/docker-compose up -d
    '';
  };
}
