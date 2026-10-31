{
  config,
  lib,
  pkgs,
  ...
}: let
  runner = config.services.forgejo-actions-runner;
  cfg = runner.holdMonitor;
  storage = config.services.storage-health-monitor;
  enabled = runner.enable && cfg.enable;
  game = runner.ioPressureGuard.admissionControl.gameProcess;
  # A standby runner's start gate refuses it until its controller admits it.
  standbyUnits =
    builtins.filter (
      unit: (config.systemd.services.${lib.removeSuffix ".service" unit}.environment.RUNNER_STANDBY or "0") == "1"
    )
    runner.runnerUnits;
  monitor = pkgs.writeShellApplication {
    name = "forgejo-runner-hold-monitor";
    runtimeInputs = with pkgs; [coreutils curl systemd];
    text = builtins.readFile ./hold-monitor.sh;
  };
in {
  options.services.forgejo-actions-runner.holdMonitor = {
    enable = lib.mkEnableOption "alerting when runner admission stays held beyond a bound";
    pingBaseFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default =
        if storage.enable
        then storage.pingBaseFile
        else null;
      defaultText = lib.literalExpression "config.services.storage-health-monitor.pingBaseFile when that monitor is enabled, else null";
      description = "Runtime file containing the private Healthchecks ping base.";
    };
    slug = lib.mkOption {
      type = lib.types.strMatching "[a-z0-9-]+";
      default = "ci-runners-${config.networking.hostName}";
      description = "Healthchecks check slug, created on first ping.";
    };
    maxHoldMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = ''
        Report a runner that has not been active for this long, unless a
        detected game, an unadmitted standby or a running Podman store reset
        holds it on purpose.
      '';
    };
    interval = lib.mkOption {
      type = lib.types.str;
      default = "5m";
      description = "Interval between checks.";
    };
  };

  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = cfg.pingBaseFile != null;
        message = "services.forgejo-actions-runner.holdMonitor needs pingBaseFile, or an enabled storage-health-monitor to take it from.";
      }
    ];

    systemd.services.forgejo-runner-hold-monitor = {
      description = "Report Forgejo runner admission held beyond its bound";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      environment = {
        RUNNER_UNITS = lib.concatStringsSep " " runner.runnerUnits;
        STANDBY_UNITS = lib.concatStringsSep " " standbyUnits;
        MAX_HOLD_SECONDS = toString (cfg.maxHoldMinutes * 60);
        GAME_ADMISSION_ENABLED =
          if game.enable
          then "1"
          else "0";
        # The guard refreshes its game record every sample; allow the cooldown
        # plus a minute before treating the record as stale.
        GAME_HOLD_SECONDS = toString (game.cooldownSeconds + 60);
        PING_BASE_FILE = toString cfg.pingBaseFile;
        SLUG = cfg.slug;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe monitor;
        RuntimeDirectory = "forgejo-runner-hold-monitor";
        RuntimeDirectoryMode = "0700";
        # Hold start times must survive between runs.
        RuntimeDirectoryPreserve = "yes";
        # The guard's state is only read, never written.
        ReadOnlyPaths = ["-/run/forgejo-runner-aggregate-pressure" "-/run/forgejo-podman-store-reset"];
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        TimeoutStartSec = "2min";
      };
    };
    systemd.timers.forgejo-runner-hold-monitor = {
      description = "Check Forgejo runner admission holds";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = cfg.interval;
        OnUnitActiveSec = cfg.interval;
        Persistent = false;
        RandomizedDelaySec = "0";
      };
    };
  };
}
