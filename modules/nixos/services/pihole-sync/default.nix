{ config, lib, pkgs, ... }:

{
  systemd.services.pihole-sync = {
    description = "Pi-hole Teleporter Sync (NUX → RPi)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      StandardOutput = "journal";
      StandardError = "journal";
      ExecStart = "${pkgs.bash}/bin/bash -c 'export PIHOLE_ADMIN_PASSWORD=$(cat ${config.sops.secrets.pihole_secret_key.path}); /home/alc/dev/git/alcxyz/gitops/nux/pihole/scripts/pihole-sync/pihole-sync -config /home/alc/dev/git/alcxyz/gitops/nux/pihole/scripts/pihole-sync/config.toml'";
    };
  };

  systemd.timers.pihole-sync = {
    description = "Hourly Pi-hole sync timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "1h";
      Persistent = true;
    };
  };
}
