# nix-config/modules/nixos/services/pihole-sync/default.nix
{ config, pkgs, inputs, lib, configDir, ... }:

let
  cfg = config.services.pihole-sync;
in
{
  options.services.pihole-sync = {
    enable = lib.mkEnableOption "Pi-hole Teleporter sync service";

    user = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "User to run the service as.";
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      default = "${configDir}/users/alc/configs/pihole-sync/config.toml";
      description = ''
        Path (in the Nix store) to the pihole-sync config.toml.

        Default points at your repo's:
        users/alc/configs/pihole-sync/config.toml
      '';
      example = "/nix/store/...-source/users/alc/configs/pihole-sync/config.toml";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      # systemd OnCalendar expression; 'hourly' is reasonable default
      default = "hourly";
      description = "Systemd timer schedule (OnCalendar value).";
      example = "*-*-* 02:00:00";
    };

    verbose = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable verbose logging from the sync process.";
    };
  };

  config = lib.mkIf cfg.enable {

    # ---------- sops secret ----------
    sops.secrets.pihole_secret_key = {
      sopsFile = "${inputs.nix-secrets}/shared/secrets.yaml";
      owner = cfg.user;
      group = "root";
      mode = "0400";
    };

    # ---------- systemd service ----------
    systemd.services.pihole-sync = {
      description = "Pi-hole Teleporter Sync Service (Go binary from nix-packages)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = "root";

        # Work in /var/lib/pihole-sync so that the relative log path
        # "./logs/pihole-sync.log" in config.toml ends up there.
        WorkingDirectory = "/var/lib/pihole-sync";

        # Create working dir + logs dir, and copy the config.toml
        ExecStartPre = lib.concatStringsSep " " [
          "${pkgs.coreutils}/bin/mkdir -p /var/lib/pihole-sync/logs"
          "&&"
          "${pkgs.coreutils}/bin/cp"
          cfg.configFile
          "/var/lib/pihole-sync/config.toml"
        ];

        # Wrap the Go binary to inject the secret and run with the copied config
        ExecStart = pkgs.writeShellScript "pihole-sync-wrapper" ''
          set -euo pipefail
          export PIHOLE_ADMIN_PASSWORD="$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.pihole_secret_key.path})"
          exec ${pkgs.pihole-sync}/bin/pihole-sync \
            -config /var/lib/pihole-sync/config.toml \
            ${lib.optionalString cfg.verbose "-verbose"}
        '';

        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "pihole-sync";
      };
    };

    # ---------- timer ----------
    systemd.timers.pihole-sync = {
      description = "Timer to run pihole-sync on schedule.";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        Unit = "pihole-sync.service";
      };
    };
  };
}
