{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.forgejo-actions-runner;
  cleanup = cfg.idlePodmanCleanup;
  enabled = cfg.enable && cleanup.enable;
  helper = pkgs.writeShellApplication {
    name = "forgejo-idle-podman-cleanup";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gawk
      jq
      ripgrep
      systemd
      util-linux
    ];
    text = builtins.readFile ./idle-podman-cleanup.sh;
  };
in {
  options.services.forgejo-actions-runner.idlePodmanCleanup = {
    enable = lib.mkEnableOption "bounded Podman CI cache cleanup while both runners are inactive";
    triggerUsedPercent = lib.mkOption {
      type = lib.types.ints.between 1 99;
      default = 70;
      description = "Run idle Podman cleanup when root filesystem usage reaches this percentage.";
    };
    interval = lib.mkOption {
      type = lib.types.str;
      default = "30min";
      description = "Interval between idle cleanup checks.";
    };
  };

  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = cfg.podmanCanary.enable && cfg.isolatedDocker.enable && cfg.ioPressureGuard.admissionControl.enable && cfg.ioPressureGuard.diskSpace.enable;
        message = "Idle Podman cleanup requires the isolated Docker and Podman runners with disk-space admission control.";
      }
    ];

    systemd.services.forgejo-idle-podman-cleanup = {
      description = "Prune old idle Podman CI artifacts under disk pressure";
      after = [
        "forgejo-runner-io-pressure-guard.service"
        "forgejo-runner-docker.service"
        "forgejo-runner-podman.service"
      ];
      restartIfChanged = false;
      environment = {
        TRIGGER_USED_PERCENT = toString cleanup.triggerUsedPercent;
        CRITICAL_FREE_BYTES = toString (cfg.ioPressureGuard.diskSpace.criticalFreeGiB * 1024 * 1024 * 1024);
        CRITICAL_FREE_PERCENT = toString cfg.ioPressureGuard.diskSpace.criticalFreePercent;
        DISK_PATH = cfg.ioPressureGuard.diskSpace.path;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/timeout -k 2s 60s ${lib.getExe helper}";
        TimeoutStartSec = "65s";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };
    systemd.timers.forgejo-idle-podman-cleanup = {
      description = "Check idle Podman CI cache pressure";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "20min";
        OnUnitActiveSec = cleanup.interval;
        RandomizedDelaySec = "5min";
        Persistent = false;
      };
    };
  };
}
