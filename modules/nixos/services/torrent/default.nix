# modules/nixos/services/torrent/default.nix
{ config, pkgs, lib, username, ... }:

# This module configures a Docker-based rTorrent + Flood stack using jesec's images.
# It should be imported directly into your main configuration.nix.

{
  # ====================================================================
  # 1. Enable Docker and Add User to Docker Group
  # ====================================================================
  virtualisation.docker.enable = true;
  users.users.${username}.extraGroups = [ "docker" ];

  # ====================================================================
  # 2. Manage Host Directories and Permissions for Docker Volumes
  # ====================================================================
  # This is crucial to avoid permission errors inside the containers.
  # We create the directories and set their ownership to your primary user,
  # which will match the PUID/PGID used in the containers.
  systemd.tmpfiles.rules = [
    # Config directory for rTorrent session files and Flood's config.
    # Owned by your user, writable by the media group.
    "d /var/lib/rtorrent 0775 ${username} media -"

    # Data directory for downloads.
    "d /zpool/downloads 0775 ${username} media -"

    # Watch directory for automatically adding .torrent files.
    "d /zpool/downloads/watch 0775 ${username} media -"
  ];

  # ====================================================================
  # 3. Configure Firewall
  # ====================================================================
  networking.firewall = {
    # Open the P2P port for rTorrent for both TCP and UDP.
    allowedTCPPorts = [ 51413 ];
    allowedUDPPorts = [ 51413 ];
  };

  # ====================================================================
  # 4. Declaratively Define Docker Containers
  # ====================================================================
  # We use NixOS's declarative container management instead of a separate
  # docker-compose.yml file. This keeps your entire system config in Nix.
  virtualisation.oci-containers.containers = {
    rtorrent = {
      image = "jesec/rtorrent:latest";
      # CRITICAL: Replace '1000:983' with your actual PUID:PGID.
      # Find with: `id -u andre` and `id -g media`
      user = "1000:983"; # PUID:PGID
      volumes = [
        "/var/lib/rtorrent:/config" # Host config path -> Container
        "/zpool/downloads:/data"   # Host data path -> Container
      ];
      ports = [
        "51413:51413/tcp" # Expose P2P port
        "51413:51413/udp"
      ];
      # Set rTorrent's P2P port and run it as a daemon.
      # Each argument is a separate string in the list, with NO COMMAS.
      cmd = [ # <--- CORRECTED: The option is 'cmd', not 'command'
        "-o" "network.port_range.set=51413-51413"
        "-o" "system.daemon.set=true"
      ];
      extraOptions = [ "--restart=unless-stopped" ];
    };

    flood = {
      image = "jesec/flood:latest";
      # CRITICAL: Use the same PUID:PGID as the rtorrent container.
      user = "1000:983"; # PUID:PGID
      volumes = [
        "/var/lib/rtorrent:/config" # Shared config volume for socket communication
        "/zpool/downloads:/data"   # So Flood can see the torrent data
      ];
      # Expose Flood's web UI port to the host for Traefik to connect to.
      ports = [ "8112:8112" ];
      environment = {
        # This is required by the jesec/flood image.
        HOME = "/config";
      };
      # Set Flood's web port and the path it's allowed to access.
      cmd = [ "--port" "8112" "--allowedpath" "/data" ]; # <--- CORRECTED: The option is 'cmd', not 'command'
      extraOptions = [ "--restart=unless-stopped" ];
      # Add Traefik labels to expose Flood via your reverse proxy.
      labels = {
        "traefik.enable" = "true";
        "traefik.http.routers.flood.rule" = "Host(`deluge.xyz.local`)";
        "traefik.http.routers.flood.entrypoints" = "websecure";
        "traefik.http.routers.flood.service" = "flood";
        "traefik.http.routers.flood.tls" = "true";
        # Traefik targets the host port that the container is mapped to.
        "traefik.http.services.flood.loadbalancer.servers.0.url" = "http://localhost:8112";
      };
    };
  };
}
