# The runner hold (ADR-0106): one controller that stops the isolated CI
# runners while a game runs or free space is below the disk floor, and starts
# them again when that ends. The start gate refuses runner starts for the same
# reasons, and the Podman store reset hands it the runners it cannot start.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.forgejo-actions-runner;
  hold = cfg.runnerHold;
  game = config.services.gameSignal;
  storage = config.services.storage-health-monitor;
  enabled = cfg.enable && cfg.isolatedDocker.enable;
  stateDir = "/run/forgejo-runner-hold";
  controller = pkgs.writeShellApplication {
    name = "forgejo-runner-hold";
    runtimeInputs = with pkgs; [coreutils curl gawk systemd];
    text = builtins.readFile ./runner-hold.sh;
  };
  gate = pkgs.writeShellApplication {
    name = "forgejo-runner-start-gate";
    runtimeInputs = with pkgs; [coreutils gawk systemd util-linux];
    text = builtins.readFile ./runner-start-gate.sh;
  };
in {
  options.services.forgejo-actions-runner.runnerHold = {
    game.enable = lib.mkEnableOption ''
      holding the runners while the host's game signal reports a game
      (services.gameSignal); a runner's running jobs then get the runner's
      shutdownTimeoutSeconds to finish before they are cancelled'';

    diskSpace = {
      enable = lib.mkEnableOption "holding the runners while free space is below a floor";
      path = lib.mkOption {
        type = lib.types.str;
        default = "/";
        description = "Filesystem path whose free space protects runner storage.";
      };
      drainFreeGiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Hold the runners when available space falls below this many GiB.";
      };
      drainFreePercent = lib.mkOption {
        type = lib.types.ints.between 1 99;
        default = 15;
        description = "Hold the runners when free space falls below this percentage.";
      };
      recoveryFreeGiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 40;
        description = "Release the runners only once at least this many GiB are available.";
      };
      recoveryFreePercent = lib.mkOption {
        type = lib.types.ints.between 1 99;
        default = 20;
        description = "Release the runners only once at least this percentage is free.";
      };
    };

    alert = {
      enable = lib.mkEnableOption ''
        reporting to Healthchecks a runner left inactive or failed for longer
        than maxInactiveMinutes with no hold reason, marker or running Podman
        store reset to explain it'';
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
        default = "ci-runners-${lib.toLower config.networking.hostName}";
        defaultText = lib.literalExpression ''"ci-runners-''${lib.toLower config.networking.hostName}"'';
        description = "Healthchecks check slug, created on first ping.";
      };
      maxInactiveMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Report a runner inactive or failed for this long without a hold.";
      };
      intervalSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = "Interval between checks and pings.";
      };
    };

    sampleSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Interval between hold samples.";
    };

    gateEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      internal = true;
      description = "Environment of the runner start gate, shared by every runner unit.";
    };

    gate = lib.mkOption {
      type = lib.types.package;
      default = gate;
      readOnly = true;
      internal = true;
      description = "The runner start gate.";
    };
  };

  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = !hold.game.enable || game.enable;
        message = "services.forgejo-actions-runner.runnerHold.game needs services.gameSignal.";
      }
      {
        assertion =
          hold.diskSpace.drainFreeGiB
          < hold.diskSpace.recoveryFreeGiB
          && hold.diskSpace.drainFreePercent < hold.diskSpace.recoveryFreePercent;
        message = "Runner disk floors must order drain < recovery for both GiB and percent.";
      }
      {
        assertion = !hold.alert.enable || hold.alert.pingBaseFile != null;
        message = "services.forgejo-actions-runner.runnerHold.alert needs pingBaseFile, or an enabled storage-health-monitor to take it from.";
      }
    ];

    services.forgejo-actions-runner.runnerHold.gateEnvironment = {
      STATE_DIR = stateDir;
      GAME_ENABLED =
        if hold.game.enable
        then "1"
        else "0";
      GAME_FILE = game.file;
      GAME_UNIT = game.unit;
      DISK_HELPER_FILE = "${./disk-space-admission.sh}";
      DISK_SPACE_ENABLED =
        if hold.diskSpace.enable
        then "1"
        else "0";
      DISK_SPACE_PATH = hold.diskSpace.path;
      DISK_DRAIN_BYTES = toString (hold.diskSpace.drainFreeGiB * 1024 * 1024 * 1024);
      DISK_DRAIN_PERCENT = toString hold.diskSpace.drainFreePercent;
      DISK_RECOVERY_BYTES = toString (hold.diskSpace.recoveryFreeGiB * 1024 * 1024 * 1024);
      DISK_RECOVERY_PERCENT = toString hold.diskSpace.recoveryFreePercent;
    };

    # The start lock and the markers exist before any controller, gate or
    # reset runs, and survive a controller restart.
    systemd.tmpfiles.rules =
      ["d ${stateDir} 0700 root root -"]
      ++ map (unit: "d ${stateDir}/runners/${unit} 0700 root root -") cfg.runnerUnits;

    systemd.services.forgejo-runner-hold = {
      description = "Hold the CI runners while a game runs or disk space is low";
      wantedBy = ["multi-user.target"];
      after = lib.optional hold.game.enable game.unit;
      environment =
        hold.gateEnvironment
        // {
          RUNNER_UNITS = lib.concatStringsSep " " cfg.runnerUnits;
          SAMPLE_SECONDS = toString hold.sampleSeconds;
          ALERT_ENABLED =
            if hold.alert.enable
            then "1"
            else "0";
          ALERT_INTERVAL_SECONDS = toString hold.alert.intervalSeconds;
          MAX_INACTIVE_SECONDS = toString (hold.alert.maxInactiveMinutes * 60);
          PING_BASE_FILE = toString hold.alert.pingBaseFile;
          SLUG = hold.alert.slug;
        };
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        ExecStart = lib.getExe controller;
        # It keeps no state beyond the markers, so it may restart at any time.
        Restart = "always";
        RestartSec = "5s";
      };
    };

    services.storage-health-monitor.units = lib.mkIf storage.enable [
      {
        name = "forgejo-runner-hold.service";
        mode = "active-not-degraded";
      }
    ];

    # A runner the hold or its gate keeps stopped is no failed boot.
    services.nixfleet-boot-check.runnerUnits =
      map (unit: {
        inherit unit;
        holdMarkerDirectory = "${stateDir}/runners/${unit}";
      })
      cfg.runnerUnits;
  };
}
