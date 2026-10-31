{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.forgejo-actions-runner;
  reset = cfg.podmanStoreReset;
  enabled = cfg.enable && reset.enable;
  game = config.services.gameSignal;
  helper = pkgs.writeShellApplication {
    name = "forgejo-podman-store-reset";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gawk
      gnugrep
      jq
      procps
      systemd
      util-linux
    ];
    text = builtins.readFile ./podman-store-reset.sh;
  };
in {
  options.services.forgejo-actions-runner.podmanStoreReset = {
    enable = lib.mkEnableOption ''
      offline reset of the dedicated Podman CI store while its runners are
      idle: stop the running runners and both APIs, rename the store aside
      under the lifecycle lock, start them again and delete the old store at
      the lowest priority (ADR-0105)
    '';
    ioPressurePercent = lib.mkOption {
      type = lib.types.ints.between 0 100;
      default = 5;
      description = "Start a reset, and keep deleting the old store, only while full I/O PSI avg10 stays at or below this percentage.";
    };
    quietMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 15;
      description = ''
        Stop a runner only if it has started no job for this long. A job
        that is still pulling its image has no task container yet, and a
        runner stop would cancel it once the runner's shutdown timeout passes.
      '';
    };
    triggerUsedPercent = lib.mkOption {
      type = lib.types.ints.between 1 99;
      default = 70;
      description = "Reset when usage of the filesystem holding the Podman store reaches this percentage, at most every six hours.";
    };
    maxAgeDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7;
      description = "Reset a store that has not been reset for this many days.";
    };
    interval = lib.mkOption {
      type = lib.types.str;
      default = "15min";
      description = "Interval between checks. A check that finds no reset due, or busy runners, changes nothing.";
    };
  };

  config = lib.mkIf enabled {
    assertions = [
      {
        # The runner hold starts a runner whose restart a start gate refused.
        assertion = cfg.podmanCanary.enable && cfg.isolatedDocker.enable;
        message = "The Podman store reset requires the isolated Docker and Podman runners.";
      }
    ];

    services.storage-health-monitor.units = lib.mkIf config.services.storage-health-monitor.enable [
      {
        name = "forgejo-podman-store-reset.service";
        mode = "recent-success";
        # The longest run (TimeoutStartSec) plus the interval and its delay.
        maximumAgeSeconds = 10800;
        allowPendingFirstTimer = true;
        # OnBootSec + maximum randomized delay + default AccuracySec.
        pendingFirstTimerMaximumAgeSeconds = 1320;
      }
    ];

    systemd.services.forgejo-podman-store-reset = {
      description = "Reset the dedicated Podman CI store while its runners are idle";
      # No ordering against the APIs or runners: ExecStopPost waits for their
      # starts, which a stop job of this unit would otherwise hold back.
      restartIfChanged = false;
      environment = {
        STORE_PATH = cfg.podmanCanary.storageRoot;
        TRIGGER_USED_PERCENT = toString reset.triggerUsedPercent;
        MAX_AGE_SECONDS = toString (reset.maxAgeDays * 86400);
        IO_PRESSURE_THRESHOLD_HUNDREDTHS = toString (reset.ioPressurePercent * 100);
        QUIET_SECONDS = toString (reset.quietMinutes * 60);
        # The longest runner stop: its shutdown timeout and the cleanup after.
        RUNNER_STOP_TIMEOUT_SECONDS = toString (cfg.shutdownTimeoutSeconds + 300);
        RUNNER_UNITS = lib.concatStringsSep " " cfg.runnerUnits;
        GAME_ENABLED =
          if cfg.runnerHold.game.enable
          then "1"
          else "0";
        GAME_FILE = game.file;
        GAME_UNIT = game.unit;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe helper;
        # Starts whatever a failed or killed run left stopped.
        ExecStopPost = lib.mkBefore ["${lib.getExe helper} restart"];
        # Leftover trash (30 minutes), runner stops (bounded by the runners'
        # stop timeouts, normally seconds since the runners are idle), the API
        # stop and start, and the new trash (30 minutes).
        TimeoutStartSec = "140min";
        # ExecStopPost waits for the starts it requests (up to 5 minutes).
        TimeoutStopSec = "10min";
        StateDirectory = "forgejo-podman-store-reset";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "forgejo-podman-store-reset";
        RuntimeDirectoryMode = "0700";
        # ExecStopPost and the runner hold read the restart list.
        RuntimeDirectoryPreserve = "yes";
      };
    };
    systemd.timers.forgejo-podman-store-reset = {
      description = "Check whether the Podman CI store is due for a reset";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "20min";
        OnUnitActiveSec = reset.interval;
        RandomizedDelaySec = "1min";
        Persistent = false;
      };
    };
  };
}
