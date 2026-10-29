{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.forgejo-actions-runner;
  cleanup = cfg.idlePodmanCleanup;
  enabled = cfg.enable && cleanup.enable;
  runnerUnits = lib.concatStringsSep " " cfg.runnerUnits;
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
    # The jq programs use their own $variables inside single quotes.
    excludeShellChecks = ["SC2016"];
    text = builtins.readFile ./idle-podman-cleanup.sh;
  };
  recovery = pkgs.writeShellApplication {
    name = "forgejo-runner-cleanup-fence-recover";
    runtimeInputs = with pkgs; [coreutils gawk systemd util-linux];
    text =
      ''
        [[ $EUID == 0 ]] || { echo "Root execution required" >&2; exit 1; }
        # Bake the configured runner list into the operator command.
        RUNNER_UNITS=${lib.escapeShellArg runnerUnits}
      ''
      + builtins.readFile ./cleanup-fence-recover.sh;
  };
in {
  options.services.forgejo-actions-runner.idlePodmanCleanup = {
    enable = lib.mkEnableOption "bounded Podman CI cache cleanup while every runner is inactive";
    pressureOnly = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Require the store filesystem to reach triggerUsedPercent before cleanup.
        Disable to remove eligible old artifacts in any existing safe idle window.
        This does not drain runners or guarantee a cleanup deadline.
      '';
    };
    triggerUsedPercent = lib.mkOption {
      type = lib.types.ints.between 1 99;
      default = 70;
      description = "Run idle Podman cleanup when usage of the filesystem holding the Podman store reaches this percentage.";
    };
    imageMinAge = lib.mkOption {
      type = lib.types.strMatching "[1-9][0-9]*h";
      default = "48h";
      description = "Minimum time since creation, in hours, of unused Podman images removed by idle cleanup.";
    };
    interval = lib.mkOption {
      type = lib.types.str;
      # Runners are idle only during short admission drains, so a long interval
      # misses most cleanup windows. Checks outside a window exit immediately.
      default = "5min";
      description = "Interval between idle cleanup checks. Set healthMaximumAgeSeconds to cover this interval, scheduling delay and cleanup runtime when health monitoring is enabled.";
    };
    healthMaximumAgeSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1800;
      description = "Maximum age of a successful cleanup check for optional health monitoring. Increase this when using a longer cleanup interval; retained completion fences fail health checks immediately regardless of this age.";
    };
  };

  config = lib.mkIf enabled {
    environment.systemPackages = [recovery];
    assertions = [
      {
        assertion = cfg.podmanCanary.enable && cfg.isolatedDocker.enable && cfg.ioPressureGuard.admissionControl.enable && cfg.ioPressureGuard.diskSpace.enable;
        message = "Idle Podman cleanup requires the isolated Docker and Podman runners with disk-space admission control.";
      }
    ];

    services.storage-health-monitor.units = lib.mkIf config.services.storage-health-monitor.enable [
      {
        name = "forgejo-idle-podman-cleanup.service";
        mode = "recent-success";
        maximumAgeSeconds = cleanup.healthMaximumAgeSeconds;
        allowPendingFirstTimer = true;
        # OnBootSec + maximum randomized delay + default AccuracySec.
        pendingFirstTimerMaximumAgeSeconds = 1320;
      }
    ];

    systemd.services.forgejo-idle-podman-cleanup = {
      description = "Remove leftover containers and old Podman CI artifacts in safe idle windows";
      after = [
        "forgejo-runner-io-pressure-guard.service"
        "forgejo-runner-docker.service"
        "forgejo-runner-podman.service"
      ];
      restartIfChanged = false;
      environment = {
        TRIGGER_USED_PERCENT = toString cleanup.triggerUsedPercent;
        PRESSURE_ONLY =
          if cleanup.pressureOnly
          then "1"
          else "0";
        CRITICAL_FREE_BYTES = toString (cfg.ioPressureGuard.diskSpace.criticalFreeGiB * 1024 * 1024 * 1024);
        CRITICAL_FREE_PERCENT = toString cfg.ioPressureGuard.diskSpace.criticalFreePercent;
        DISK_PATH = cfg.ioPressureGuard.diskSpace.path;
        STORE_PATH = cfg.podmanCanary.storageRoot;
        IMAGE_MIN_AGE = cleanup.imageMinAge;
        # Cleanup starts, and dispatches each mutation, only while the guard
        # itself would consider the host recovered from I/O pressure.
        IO_PRESSURE_THRESHOLD_HUNDREDTHS = toString (cfg.ioPressureGuard.lowPercent * 100);
        RUNNER_UNITS = runnerUnits;
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
        RandomizedDelaySec = "1min";
        Persistent = false;
      };
    };
  };
}
