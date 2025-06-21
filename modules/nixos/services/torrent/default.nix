{ config, lib, pkgs, hostName, username, ... }:

with lib;

{
  options.services.torrent = {
    enable = mkEnableOption "torrent services (rtorrent + flood)";
  };

  config = mkIf config.services.torrent.enable {
    # Ensure symlink and directories exist
    systemd.tmpfiles.rules = [
      "L+ /downloads - - - - /zpool/downloads"
      "d /zpool/downloads 0755 rtorrent rtorrent -"
      "d /zpool/downloads/watch 0755 rtorrent rtorrent -"
    ];

    # rtorrent configuration
    services.rtorrent = {
      enable = true;
      port = 51413;
      downloadDir = "/downloads";
      dataDir = "/var/lib/rtorrent";
      user = "rtorrent";
      group = "rtorrent";
      openFirewall = false; # Using traefik
      # rpcSocket is read-only, uses default: /run/rtorrent/rpc.sock
      
      configText = ''
        # Network settings
        network.port_range.set = 51413-51413
        network.port_random.set = no
        
        # Connection settings
        throttle.max_uploads.set = 100
        throttle.max_downloads.global.set = 200
        throttle.min_peers.normal.set = 20
        throttle.max_peers.normal.set = 60
        throttle.min_peers.seed.set = 30
        throttle.max_peers.seed.set = 80
        
        # Memory settings
        pieces.memory.max.set = 512M
        
        # Logging
        log.add_output = "info", "rtorrent.log"
        
        # Watch directory for auto-loading torrents
        schedule2 = watch_directory, 5, 5, ((load.start_verbose, (cat, "/downloads/watch/*.torrent")))
        
        # DHT
        dht.mode.set = auto
        dht.port.set = 6881
        protocol.pex.set = yes
        
        # Encryption
        protocol.encryption.set = allow_incoming,try_outgoing,enable_retry
      '';
    };

    # flood configuration
    services.flood = {
      enable = true;
      port = 8112;
      host = "127.0.0.1"; # Only local access, traefik handles external
      openFirewall = false; # Using traefik
      extraArgs = [
        "--rthost=unix:///run/rtorrent/rpc.sock"  # Use NixOS default socket path
        "--allowedpath=/downloads"
      ];
    };

    # Ensure flood can access rtorrent socket
    systemd.services.flood = {
      after = [ "rtorrent.service" ];
      serviceConfig = {
        SupplementaryGroups = [ "rtorrent" ];
      };
    };

    # Traefik dynamic configuration for flood
    services.traefik.dynamicConfigOptions.http.routers.flood = {
      rule = "Host(`flood.${hostName}.local`)";
      entryPoints = [ "websecure" ];
      service = "flood";
      tls = true;
    };

    services.traefik.dynamicConfigOptions.http.services.flood = {
      loadBalancer.servers = [
        { url = "http://127.0.0.1:8112"; }
      ];
    };

    users.users.${username}.extraGroups = [ "rtorrent" ]; 

    # Open firewall for torrent port
    networking.firewall.allowedTCPPorts = [ 51413 ];
    networking.firewall.allowedUDPPorts = [ 51413 6881 ]; # DHT port
  };
}
