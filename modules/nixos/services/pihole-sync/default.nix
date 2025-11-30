{ config, lib, pkgs, ... }:

let
  syncScript = pkgs.writeShellScript "pihole-sync-run" ''
    export PIHOLE_ADMIN_PASSWORD=$(cat ${config.sops.secrets.pihole_secret_key.path})
    /home/alc/dev/git/alcxyz/gitops/nux/pihole/scripts/pihole-sync/pihole-sync \
      -config /home/alc/dev/git/alcxyz/gitops/nux/pihole/scripts/pihole-sync/config.toml
  '';
in
{
  systemd.services.pihole-sync = {
    description = "Pi-hole Teleporter Sync (NUX → RPi)";
    script = "${syncScript}";
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  systemd.timers.pihole-sync = {
    description = "Hourly Pi-hole Sync Timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1h";
      Persistent = true;
    };
  };
}
