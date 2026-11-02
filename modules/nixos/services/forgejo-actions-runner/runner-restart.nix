# Runner status and restart when idle for nixfleet (ADR-0041,
# nix-packages ADR-0017). The runners, the engine APIs and the resource
# policy have restartIfChanged = false, so a switch leaves them running the
# definition they started with. Each records that definition when it starts;
# nixfleet-runner-status tells, without root, which runner is down and why
# and which unit needs a restart; forgejo-runner-restart restarts those units
# once every runner on the host is idle.
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
  dockerApiUnit = "forgejo-runner-docker.service";
  podmanApiUnit = "forgejo-runner-podman.service";
  policyUnit = "forgejo-runner-resource-policy.service";
  resetUnit = "forgejo-podman-store-reset.service";
  serviceUnits =
    [dockerApiUnit]
    ++ lib.optional cfg.podmanCanary.enable podmanApiUnit
    ++ lib.optional cfg.resourcePolicy.enable policyUnit;
  trackedUnits = cfg.runnerUnits ++ serviceUnits;
  # The longest restart: a runner that took a job after the last idle check
  # waits for it up to its stop timeout, then an API stops and starts.
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
    runtimeInputs = with pkgs; [coreutils curl gnugrep jq systemd];
    text = builtins.readFile ./runner-restart.sh;
  };
in {
  options.services.forgejo-actions-runner.restartWhenIdle = {
    waitMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        How long forgejo-runner-restart waits for every runner to be idle
        before it gives up and leaves the units running.
      '';
    };
    quietMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = ''
        A runner counts as idle only if it has taken no task for this long:
        a job still pulling its image has no container yet.
      '';
    };
  };

  config = lib.mkIf enabled {
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
      "d ${stateDir}/started 0755 root root -"
    ];

    # Record the definition each start uses. A failed record only leaves the
    # unit flagged for a restart, so it never fails the start.
    systemd.services =
      lib.genAttrs (map (lib.removeSuffix ".service") trackedUnits) (_: {
        serviceConfig.ExecStartPost = ["-+${lib.getExe recorder} %n"];
      })
      // {
        forgejo-runner-restart = {
          description = "Restart the CI runner units that run an older definition, once the runners are idle";
          # A switch must not cut a wait or a restart short.
          restartIfChanged = false;
          environment =
            common
            // {
              RUNNER_UNITS = lib.concatStringsSep " " cfg.runnerUnits;
              SERVICE_UNITS = lib.concatStringsSep " " serviceUnits;
              RESET_UNIT = lib.optionalString cfg.podmanStoreReset.enable resetUnit;
              DOCKER_API_UNIT = dockerApiUnit;
              DOCKER_SOCKET = lib.removePrefix "unix://" cfg.dockerHost;
              PODMAN_API_UNIT = lib.optionalString cfg.podmanCanary.enable podmanApiUnit;
              PODMAN_SOCKET = cfg.podmanCanary.socketPath;
              STATE_FILE = "${stateDir}/restart";
              WAIT_SECONDS = toString (restart.waitMinutes * 60);
              QUIET_SECONDS = toString (restart.quietMinutes * 60);
              RESTART_TIMEOUT_SECONDS = toString restartTimeoutSeconds;
            };
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe restarter;
            TimeoutStartSec = "${toString (restart.waitMinutes * 60 + restartTimeoutSeconds + 300)}s";
          };
        };
      };

    environment.systemPackages = [status];
  };
}
