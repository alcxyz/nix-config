# nix-config/modules/nixos/services/pihole-sync/default.nix
{ config, pkgs, inputs, lib, ... }:

let
  cfg = config.services.pihole-sync;

  # ---- Source ----
  # Path to your local Go project (inside nix-config)
  srcPath = "${inputs.self}/scripts/pihole-sync/pihole-sync";

  # ---- Build ----
  piholeSyncPkg = pkgs.buildGoModule {
    pname = "pihole-sync";
    version = "0.1.0";
    src = srcPath;

    # For reproducibility, lock vendor deps later:
    vendorHash = null;

    subPackages = [ "." ];
  };

  # ---- Wrapper ----
  # Reads secret and passes it as env var to Go program
  wrapper = pkgs.writeShellScript "pihole-sync-wrapper" ''
    set -euo pipefail
    export PIHOLE_ADMIN_PASSWORD="$(cat ${config.sops.secrets.pihole_admin_password.path})"

    exec ${piholeSyncPkg}/bin/pihole-sync \
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
      default = "${srcPath}/config.toml";
      description = "Path to the Pi-hole sync TOML configuration file.";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "Systemd timer schedule (e.g., 'hourly' or '*-*-* 02:00:00')";
    };

    verbose = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable verbose logging output.";
    };
  };

  config = lib.mkIf cfg.enable {
    # ---- Secret Integration (via sops-nix) ----
    sops.secrets.pihole_admin_password = {
      sopsFile = "${inputs.nix-secrets}/hosts/nux/secrets.yaml";
      owner = cfg.user;
      group = "root";
      mode = "0400";
    };

    # ---- Systemd Service ----
    systemd.services.pihole-sync = {
      description = "Pi-hole Teleporter Sync Service";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = "root";
        ExecStart = wrapper;
        WorkingDirectory = "/var/lib/pihole-sync";
        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "pihole-sync";
      };
    };

    # ---- Systemd Timer ----
    systemd.timers.pihole-sync = {
      description = "Timer to periodically run pihole-sync";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        Unit = "pihole-sync.service";
      };
    };

    environment.systemPackages = [ piholeSyncPkg ];
  };
}
