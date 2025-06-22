{ config, lib, pkgs, username, hostName, ... }:

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
      "d /zpool/downloads/completed 0755 rtorrent rtorrent -"
      "d /var/lib/rtorrent 0755 rtorrent rtorrent -"
      "d /var/lib/rtorrent/session 0755 rtorrent rtorrent -"
      "d /var/lib/flood 0755 flood flood -"
    ];

    # rtorrent configuration
    services.rtorrent = {
      enable = true;
      port = 51413;
      downloadDir = "/downloads";
      dataDir = "/var/lib/rtorrent";
      user = "rtorrent";
      group = "rtorrent";
      openFirewall = false;
      
      configText = ''
        # Network settings
        network.port_range.set = 51413-51413
        network.port_random.set = no
        
        # Enable DHT and PEX (overriding NixOS defaults)
        dht.mode.set = auto
        protocol.pex.set = yes
        trackers.use_udp.set = yes
        
        # Basic limits
        throttle.max_downloads.global.set = 200
        throttle.max_uploads.global.set = 100
        
        # Peer limits
        throttle.min_peers.normal.set = 20
        throttle.max_peers.normal.set = 60
        throttle.min_peers.seed.set = 30
        throttle.max_peers.seed.set = 80
        
        # Memory limit
        pieces.memory.max.set = 512M
        
        # Encryption
        protocol.encryption.set = allow_incoming,try_outgoing,enable_retry
        
        # Watch directory for torrents
        schedule2 = watch_directory, 5, 5, "load.start=/downloads/watch/*.torrent"
        
        # Move completed downloads
        method.insert = d.get_finished_dir, simple, "cat=/downloads/completed/,$d.name="
        method.insert = d.move_to_complete, simple, "d.directory.set=$argument.1=; execute=mkdir,-p,$argument.1=; execute=mv,-u,$argument.0=,$argument.1=; d.save_full_session="
        method.set_key = event.download.finished,move_complete,"d.move_to_complete=$d.data_path=,$d.get_finished_dir="
      '';
    };

    # flood configuration - simplified
    services.flood = {
      enable = true;
      openFirewall = false;
      extraArgs = [
        "--host=127.0.0.1"
        "--port=8112"
        "--rthost=unix:///run/rtorrent/rpc.sock"
        "--allowedpath=/downloads"
      ];
    };

    # Ensure flood can access rtorrent socket
    systemd.services.flood = {
      after = [ "rtorrent.service" ];
      wants = [ "rtorrent.service" ];
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
    networking.firewall.allowedUDPPorts = [ 51413 6881 ];
  };
}
