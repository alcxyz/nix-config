# modules/nixos/services/torrent/docker.nix
{ config, lib, pkgs, hostName, username, ... }:

with lib;

let
  torrentUser = config.services.torrent.user;
  torrentGroup = config.services.torrent.group;
in
{
  options.services.torrent = {
    enable = mkEnableOption "torrent services (rtorrent + flood) via Docker";
    user = mkOption {
      type = types.str;
      default = "rtorrent";
      description = "User to run rtorrent as";
    };
    group = mkOption {
      type = types.str;
      default = "rtorrent";
      description = "Group to run rtorrent as";
    };
  };

  config = mkIf config.services.torrent.enable {
    # Enable Docker
    virtualisation.docker.enable = true;

    # Create users and groups
    users.groups.media = {};
    users.groups.${torrentGroup} = {};
    users.users.${torrentUser} = {
      isSystemUser = true;
      group = torrentGroup;
      extraGroups = [ "media" ];
      description = "rTorrent daemon user";
    };
    users.users.${username}.extraGroups = [ torrentGroup ];

    # Ensure all necessary directories exist with correct permissions
    systemd.tmpfiles.rules = [
      "L+ /downloads - - - - /zpool/downloads"
      "d /zpool/downloads 0755 ${torrentUser} ${torrentGroup} -"
      "d /zpool/downloads/watch 0755 ${torrentUser} ${torrentGroup} -"
      "d /zpool/downloads/completed 0755 ${torrentUser} ${torrentGroup} -"
      "d /var/lib/rtorrent 0755 ${torrentUser} ${torrentGroup} -"
      "d /var/lib/rtorrent/session 0755 ${torrentUser} ${torrentGroup} -"
      "d /var/lib/rtorrent/.local/share/rtorrent 0770 ${torrentUser} ${torrentGroup} -"
    ];

    # Create the rtorrent configuration file
    environment.etc."rtorrent/rtorrent.rc".text = ''
      # --- Paths and Directories ---
      directory.default.set = /data/
      session.path.set = /config/session/
      schedule2 = watch_directory_start, 5, 5, "load.start=/data/watch/*.torrent,d.directory.set=/data/"

      # --- SCGI Socket for Flood ---
      scgi_local = /config/.local/share/rtorrent/rtorrent.sock
      execute.nothrow = chmod,770,/config/.local/share/rtorrent/rtorrent.sock

      # --- Network Settings ---
      network.port_range.set = 51413-51413
      network.port_random.set = no
      dht.mode.set = auto
      dht.port.set = 6881
      protocol.pex.set = yes
      trackers.use_udp.set = yes
      protocol.encryption.set = allow_incoming,try_outgoing,enable_retry

      # --- Peer and Upload/Download Limits ---
      throttle.max_downloads.global.set = 200
      throttle.max_uploads.global.set = 100
      throttle.min_peers.normal.set = 20
      throttle.max_peers.normal.set = 60
      throttle.min_peers.seed.set = 30
      throttle.max_peers.seed.set = 80
      pieces.memory.max.set = 512M

      # --- Action on Completion ---
      method.insert = d.get_finished_dir, simple, "cat=/data/completed/"
      method.insert = d.move_to_complete, simple, "d.directory.set=$d.get_finished_dir=; execute=mkdir,-p,$d.get_finished_dir=; execute=mv,-u,$d.data_path=,$d.get_finished_dir="
      method.set_key = event.download.finished,move_complete,"d.move_to_complete="
    '';

    # Systemd service to copy the config file
    systemd.services.rtorrent-config-setup = {
      description = "Setup rtorrent configuration";
      wantedBy = [ "multi-user.target" ];
      serviceConfig.Type = "oneshot";
      script = ''
        cp /etc/rtorrent/rtorrent.rc /var/lib/rtorrent/.rtorrent.rc
        chown ${torrentUser}:${torrentGroup} /var/lib/rtorrent/.rtorrent.rc
        chmod 644 /var/lib/rtorrent/.rtorrent.rc
      '';
    };

    # Docker containers, aligned with author's instructions
    virtualisation.oci-containers = {
      backend = "docker";
      containers = {
        rtorrent = {
          image = "jesec/rtorrent:latest";
          hostname = "rtorrent";
          autoStart = true;
          ports = [ "51413:51413" "6881:6881/udp" ];
          environment = { PUID = "986"; PGID = "980"; };
          volumes = [ "/var/lib/rtorrent:/config" "/downloads:/data" ];
          # THE FIX: Run rtorrent without the ncurses UI, keeping it in the foreground.
          cmd = [ "-n" ];
        };

        flood = {
          image = "jesec/flood:latest";
          hostname = "flood";
          autoStart = true;
          ports = [ "127.0.0.1:8112:3001" ];
          environment = { PUID = "986"; PGID = "980"; };
          volumes = [ "/var/lib/rtorrent:/config" "/downloads:/data" ];
          cmd = [ "--port" "3001" "--allowedpath" "/data" ];
          dependsOn = [ "rtorrent" ];
        };
      };
    };

    # Set restart policy for the generated systemd services
    systemd.services.docker-rtorrent = {
      wants = [ "rtorrent-config-setup.service" ];
      after = [ "rtorrent-config-setup.service" ];
      serviceConfig = {
        Restart = "always";
        RestartSec = "5s";
      };
    };
    systemd.services.docker-flood = {
      serviceConfig = {
        Restart = "always";
        RestartSec = "5s";
      };
    };

    # Traefik and Firewall configuration
    services.traefik.dynamicConfigOptions.http.routers.flood.rule = "Host(`flood.${hostName}.local`)";
    services.traefik.dynamicConfigOptions.http.routers.flood.entryPoints = [ "websecure" ];
    services.traefik.dynamicConfigOptions.http.routers.flood.service = "flood";
    services.traefik.dynamicConfigOptions.http.routers.flood.tls = true;
    services.traefik.dynamicConfigOptions.http.services.flood.loadBalancer.servers = [{ url = "http://127.0.0.1:8112"; }];
    networking.firewall.allowedTCPPorts = [ 51413 ];
    networking.firewall.allowedUDPPorts = [ 51413 6881 ];
  };
}
