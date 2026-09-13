{
  config,
  lib,
  pkgs,
  ...
}: let
  runner = config.services.forgejo-actions-runner;
  cfg = runner.orphanMonitor;
  enabled = runner.enable && cfg.enable;
  check = pkgs.writeShellScript "forgejo-runner-orphan-check" ''
    exec ${lib.getExe cfg.package} \
      --docker-host ${lib.escapeShellArg runner.dockerHost} \
      --container-label ${lib.escapeShellArg "io.alc.forgejo-runner=${runner.name}"} \
      --forgejo-url ${lib.escapeShellArg runner.url} \
      --token-file "$CREDENTIALS_DIRECTORY/api-token" \
      ${lib.concatMapStringsSep " " (repo: "--repo ${lib.escapeShellArg repo}") cfg.repositories}
  '';
in {
  options.services.forgejo-actions-runner.orphanMonitor = {
    enable = lib.mkEnableOption "read-only completed-task container monitoring";
    package = lib.mkOption {
      type = lib.types.package;
      description = "Package providing forgejo-runner-orphan-check.";
    };
    tokenFile = lib.mkOption {
      type = lib.types.str;
      description = "Activated API credential file, loaded by systemd for this check.";
    };
    repositories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Explicit owner/repository inventory eligible for this runner.";
    };
  };

  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = runner.isolatedDocker.enable;
        message = "Runner orphan monitoring requires the isolated CI Docker daemon.";
      }
      {
        assertion = cfg.repositories != [];
        message = "Runner orphan monitoring requires an explicit repository inventory.";
      }
    ];

    systemd.services.forgejo-runner-orphan-check = {
      description = "Check for running containers belonging to completed Forgejo tasks";
      after = ["forgejo-runner-docker.service" "network-online.target"];
      path = [pkgs.docker];
      serviceConfig = {
        Type = "oneshot";
        User = "forgejo-runner";
        Group = "forgejo-runner";
        ExecStart = check;
        LoadCredential = ["api-token:${cfg.tokenFile}"];
        TimeoutStartSec = "4min";
        Nice = 10;
        CPUWeight = 10;
        IOWeight = 10;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        UMask = "0077";
      };
    };
    systemd.timers.forgejo-runner-orphan-check = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "5min";
        RandomizedDelaySec = "30s";
        Persistent = false;
      };
    };
    services.storage-health-monitor.units = lib.mkIf config.services.storage-health-monitor.enable [
      {
        name = "forgejo-runner-orphan-check.service";
        mode = "recent-success";
        maximumAgeSeconds = 900;
        allowPendingFirstTimer = true;
      }
    ];
  };
}
