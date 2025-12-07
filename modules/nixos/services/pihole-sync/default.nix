# nix-config/modules/nixos/services/pihole-sync/default.nix
{ config, pkgs, inputs, lib, ... }:

let
  cfg = config.services.pihole-sync;

  # Full path to prebuilt binary
  binaryPath = "${inputs.self}/scripts/pihole-sync/pihole-sync";

  # Wrapper script — reads sops secret and calls the binary
  wrapper = pkgs.writeShellScript "pihole-sync-wrapper" ''
    set -euo pipefail
    export PIHOLE_ADMIN_PASSWORD="$(cat ${config.sops.secrets.pihole_secret_key.path})"
    exec ${binaryPath} \
      -config ${cfg.configFile} \
      ${lib.optionalString cfg.verbose "-verbose"}
  '';
in
{
  options.services.pihole-sync = {
    enable = lib.mkEnableOption "Pi-hole Teleporter sync service";

    user = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "User to run the service as";
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      default = "${inputs.self}/scripts/pihole-sync/pihole-sync/config.toml";
      description = "Path to pihole-sync config.toml";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "Systemd timer schedule (e.g. 'hourly' or '*-*-* 02:00:00')";
    };

    verbose = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable verbose logging from the sync process.";
    };
  };

  config = lib.mkIf cfg.enable {
    # ---- sops secret ----
    sops.secrets.pihole_secret_key = {
      sopsFile = "${inputs.nix-secrets}/shared/secrets.yaml";
      owner = cfg.user;
      group = "root";
      mode = "0400";
    };

    # ---- systemd service ----
    systemd.services.pihole-sync = {
      description = "Pi-hole Teleporter Sync Service (prebuilt binary)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      preStart = ''
        mkdir -p /var/lib/pihole-sync
        cp ${inputs.self}/scripts/pihole-sync/config.toml /var/lib/pihole-sync/config.toml
      '';

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = "root";
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/lib/pihole-sync/logs";
        ExecStart = pkgs.writeShellScript "pihole-sync-wrapper" ''
          set -euo pipefail
          export PIHOLE_ADMIN_PASSWORD="$(cat ${config.sops.secrets.pihole_secret_key.path})"
          exec ${binaryPath} \
            -config /var/lib/pihole-sync/config.toml \
            ${lib.optionalString cfg.verbose "-verbose"}
        '';
        WorkingDirectory = "/var/lib/pihole-sync";
        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "pihole-sync";
      };
    };

    # ---- timer ----
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
