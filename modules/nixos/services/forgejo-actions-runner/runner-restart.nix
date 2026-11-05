# Runner status and restarts for nixfleet (ADR-0041,
# nix-packages ADR-0017). The runners, the engine APIs and the resource
# policy have restartIfChanged = false, so a switch leaves them running the
# definition they started with. Each records that definition when it starts;
# nixfleet-runner-status tells, without root, which runner is down and why
# and which unit needs a restart; forgejo-runner-restart pauses the runners
# those units touch and restarts the units once their running jobs finish.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.forgejo-actions-runner;
  restart = cfg.restartWhenIdle;
  enabled = cfg.enable && cfg.isolatedDocker.enable;
  stateDir = "/run/nixfleet-runners";
  restartUnit = "forgejo-runner-restart.service";
  pauseDir = "${stateDir}/paused";
  pauseFile = unit: "${pauseDir}/${unit}";
  dockerApiUnit = "forgejo-runner-docker.service";
  podmanApiUnit = "forgejo-runner-podman.service";
  policyUnit = "forgejo-runner-resource-policy.service";
  resetUnit = "forgejo-podman-store-reset.service";
  serviceUnits =
    [dockerApiUnit]
    ++ lib.optional cfg.podmanCanary.enable podmanApiUnit
    ++ lib.optional cfg.resourcePolicy.enable policyUnit;
  trackedUnits = cfg.runnerUnits ++ serviceUnits;
  # The longest restart: paused runners have no jobs left, but a runner's stop
  # is bounded by its stop timeout, then an API stops and starts.
  restartTimeoutSeconds = cfg.shutdownTimeoutSeconds + 300 + 300;
  common = {
    STATE_HELPER_FILE = "${./runner-state.sh}";
    RECORD_DIR = "${stateDir}/started";
  };
  # The scripts read variables that the sourced runner-state.sh sets.
  excludeShellChecks = ["SC2154"];
  exports = env: lib.concatStrings (lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}\n") env);
  recorder = pkgs.writeShellApplication {
    name = "forgejo-runner-record";
    inherit excludeShellChecks;
    runtimeInputs = with pkgs; [coreutils systemd];
    text = exports common + builtins.readFile ./runner-record.sh;
  };
  status = pkgs.writeShellApplication {
    name = "nixfleet-runner-status";
    inherit excludeShellChecks;
    runtimeInputs = with pkgs; [coreutils systemd];
    text =
      exports (common
        // {
          RUNNERS = lib.concatMapStringsSep " " (unit: "${unit}=${lib.concatStringsSep "," (cfg.runnerLabelNames.${unit} or [])}") cfg.runnerUnits;
          SERVICES = lib.concatStringsSep " " serviceUnits;
          HOLD_UNIT = "forgejo-runner-hold.service";
          RESET_UNIT = lib.optionalString cfg.podmanStoreReset.enable resetUnit;
          RESTART_UNIT = restartUnit;
          RESTART_WAIT_SECONDS = toString (restart.waitMinutes * 60);
          RESTART_STATE_FILE = "${stateDir}/restart";
        })
      + builtins.readFile ./runner-status.sh;
  };
  restarter = pkgs.writeShellApplication {
    name = "forgejo-runner-restart";
    inherit excludeShellChecks;
    runtimeInputs = with pkgs; [coreutils systemd];
    text = builtins.readFile ./runner-restart.sh;
  };
in {
  options.services.forgejo-actions-runner.restartWhenIdle = {
    waitMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = cfg.jobTimeoutSeconds / 60 + 5;
      defaultText = lib.literalExpression "config.services.forgejo-actions-runner.jobTimeoutSeconds / 60 + 5";
      description = ''
        How long forgejo-runner-restart waits for the paused runners' jobs to
        finish before it gives up and leaves the units running. The default
        lets a job that started just before the pause run to its timeout.
      '';
    };
  };

  config = lib.mkIf enabled {
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
      "d ${stateDir}/started 0755 root root -"
      "d ${pauseDir} 0755 root root -"
    ];

    # Record the definition each start uses. A failed record only leaves the
    # unit flagged for a restart, so it never fails the start.
    systemd.services =
      lib.genAttrs (map (lib.removeSuffix ".service") trackedUnits) (name: let
        isRunner = lib.elem "${name}.service" cfg.runnerUnits;
      in {
        # The runner watches this file, and reports the pause and its running
        # jobs as its status text (nix-packages ADR-0017).
        environment = lib.optionalAttrs isRunner {
          FORGEJO_RUNNER_PAUSE_FILE = pauseFile "${name}.service";
        };
        serviceConfig =
          {
            ExecStartPost = ["-+${lib.getExe recorder} %n"];
          }
          // lib.optionalAttrs isRunner {
            NotifyAccess = "main";
          };
      })
      // {
        forgejo-runner-restart = {
          description = "Restart the CI runner units that run an older definition, once their running jobs finish";
          # A switch must not cut a wait or a restart short.
          restartIfChanged = false;
          environment =
            common
            // {
              RUNNER_UNITS = lib.concatStringsSep " " cfg.runnerUnits;
              SERVICE_UNITS = lib.concatStringsSep " " serviceUnits;
              RESET_UNIT = lib.optionalString cfg.podmanStoreReset.enable resetUnit;
              STATE_FILE = "${stateDir}/restart";
              PAUSE_DIR = pauseDir;
              WAIT_SECONDS = toString (restart.waitMinutes * 60);
              RESTART_TIMEOUT_SECONDS = toString restartTimeoutSeconds;
            };
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe restarter;
            # A pause ends with the unit, however it ends.
            ExecStopPost = "${pkgs.coreutils}/bin/rm -f ${lib.concatMapStringsSep " " pauseFile cfg.runnerUnits}";
            TimeoutStartSec = "${toString (restart.waitMinutes * 60 + restartTimeoutSeconds + 300)}s";
          };
        };
      };

    environment.systemPackages = [status];
  };
}
