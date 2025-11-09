{ config, lib, pkgs, ... }:

{
  systemd.services.pihole-sync = {
    description = "Pi-hole Teleporter Sync (NUC → RPi)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = "${pkgs.bash}/bin/bash -c 'export PIHOLE_ADMIN_PASSWORD=$(cat ${config.sops.secrets.pihole_secret_key.path}); /path/to/pihole-sync -config /path/to/config.toml'";
    };
  };

  systemd.timers.pihole-sync = {
    description = "Hourly Pi-hole sync timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1h";
      Persistent = true;
    };
  };
}
