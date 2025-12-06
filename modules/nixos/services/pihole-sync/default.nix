{ config, lib, pkgs, inputs, ... }:

with lib;

let
  # Path to script you want to run after setting the password
  scriptPath = "/home/alc/dev/git/alcxyz/gitops/nux/pihole/scripts/pihole-sync";
in
{
  options.services.pihole-sync = {
    enable = mkEnableOption "Enable Pi-hole sync between nodes";
    user = mkOption {
      type = types.str;
      default = "root";
      description = "User for running the Pi-hole sync service.";
    };
    configFile = mkOption {
      type = types.path;
      default = "${scriptPath}/config.toml";
      description = "Path to the Pi-hole sync config.toml file.";
    };
    schedule = mkOption {
      type = types.str;
      default = "1h";
      description = "Systemd OnUnitActiveSec schedule interval.";
    };
  };

  config = mkIf config.services.pihole-sync.enable {
    # Make sure SOPS is available.
    imports = [ inputs.sops-nix.nixosModules.sops ];

    # Shared secrets file path
    sops.secrets."pihole.sync_admin_password" = {
      # Use shared/secrets.yaml for the password source
      sopsFile = "${inputs.nix-secrets.secrets.files.shared}";
      owner = config.services.pihole-sync.user;
    };

    # Runtime script uses the decrypted secret at activation time
    systemd.services.pihole-sync = {
      description = "Pi‑hole Teleporter Sync (NUX → RPi)";
      script = pkgs.writeShellScript "pihole-sync-run" ''
        export PIHOLE_ADMIN_PASSWORD=$(cat "${config.sops.secrets."pihole.sync_admin_password".path}")
        "${scriptPath}/pihole-sync" -config "${config.services.pihole-sync.configFile}"
      '';
      serviceConfig = {
        Type = "oneshot";
        User = config.services.pihole-sync.user;
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    systemd.timers.pihole-sync = {
      description = "Pi-hole Teleporter Sync timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = config.services.pihole-sync.schedule;
        Persistent = true;
      };
    };
  };
}
