{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.forgejo-actions-runner;
  reset = cfg.podmanStoreReset;
  enabled = cfg.enable && reset.enable;
  game = cfg.ioPressureGuard.admissionControl.gameProcess;
  helper = pkgs.writeShellApplication {
    name = "forgejo-podman-store-reset";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gawk
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
        # The guard's admission control resumes a runner whose restart a
        # start gate refused.
        assertion = cfg.podmanCanary.enable && cfg.isolatedDocker.enable && cfg.ioPressureGuard.admissionControl.enable;
        message = "The Podman store reset requires the isolated Docker and Podman runners with admission control.";
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
        # Reset starts, and trash deletion continues, only while the guard
        # itself would consider the host recovered from I/O pressure.
        IO_PRESSURE_THRESHOLD_HUNDREDTHS = toString (cfg.ioPressureGuard.lowPercent * 100);
        RUNNER_UNITS = lib.concatStringsSep " " cfg.runnerUnits;
        GAME_HELPER_FILE = "${./game-admission.sh}";
        GAME_ADMISSION_ENABLED =
          if game.enable
          then "1"
          else "0";
        GAME_USER = game.user;
        GAME_ARGV0_BASENAMES = lib.concatStringsSep " " game.argv0Basenames;
        GAME_COOLDOWN_SECONDS = toString game.cooldownSeconds;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe helper;
        # Starts whatever a failed or killed run left stopped.
        ExecStopPost = lib.mkBefore ["${lib.getExe helper} restart"];
        # Leftover trash (30 minutes), a job admitted just before its runner's
        # stop (up to an hour), the API stop and start, and the new trash
        # (30 minutes).
        TimeoutStartSec = "140min";
        # ExecStopPost waits for the starts it requests (up to 5 minutes).
        TimeoutStopSec = "10min";
        StateDirectory = "forgejo-podman-store-reset";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "forgejo-podman-store-reset";
        RuntimeDirectoryMode = "0700";
        # ExecStopPost and the hold monitor read the restart list.
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
