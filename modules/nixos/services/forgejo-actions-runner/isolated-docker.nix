{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.forgejo-actions-runner;
  enabled = cfg.enable && cfg.isolatedDocker.enable;
  retention = cfg.isolatedDocker.retention;
  pruneAge =
    if retention.enable
    then retention.unusedAge
    else "168h";
  stateDir = "/var/lib/forgejo-docker";
  runtimeDir = "/run/forgejo-docker";
  dockerCertsDir = "${stateDir}/.config/docker/certs.d";
  mirrorCaSetup = import ./registry-mirror-ca.nix {inherit cfg lib pkgs;};
  daemonConfig = (pkgs.formats.json {}).generate "forgejo-docker.json" ({
      hosts = ["unix://${runtimeDir}/docker.sock"];
      "data-root" = "${stateDir}/overlay2";
      "exec-root" = "${runtimeDir}/exec";
      pidfile = "${runtimeDir}/docker.pid";
      group = "root"; # Root inside the user namespace maps to the service's group.
      "storage-driver" = "overlay2";
      "exec-opts" = ["native.cgroupdriver=cgroupfs"];
      "default-ulimits".nofile = {
        Name = "nofile";
        Soft = 65536;
        Hard = 65536;
      };
    }
    // lib.optionalAttrs (cfg.registryMirror != null) {
      # Docker mirrors only docker.io and falls back to it when a mirror
      # fails (daemon/internal/distribution in moby v29). The explicit overlay2
      # storage-driver above selects that graphdriver pull path rather than
      # the containerd image store (daemon/image_store_choice.go).
      "registry-mirrors" = ["https://${cfg.registryMirror}"];
    }
    // lib.optionalAttrs retention.enable {
      # Docker 29's BuilderGCRule uses filter=until, not keepDuration:
      # https://github.com/moby/moby/blob/docker-v29.9.1/daemon/config/builder.go
      # Prefer old unused cache, then reclaim any eligible unused cache over the
      # target. Periodic GC cannot impose a hard quota or reclaim active builds.
      builder.gc = {
        enabled = true;
        policy = [
          {
            reservedSpace = retention.budget;
            maxUsedSpace = retention.budget;
            filter = ["until=${retention.unusedAge}"];
          }
          {
            reservedSpace = retention.budget;
            maxUsedSpace = retention.budget;
            all = true;
          }
        ];
      };
    });
  apiStartGate = pkgs.writeShellApplication {
    name = "forgejo-docker-api-start-gate";
    runtimeInputs = with pkgs; [coreutils systemd util-linux];
    text = builtins.readFile ./podman-api-start-gate.sh;
  };
in {
  options.services.forgejo-actions-runner.isolatedDocker = {
    enable = lib.mkEnableOption "experimental dedicated rootless CI Docker daemon (requires qualification before activation)";
    retention = {
      enable = lib.mkEnableOption "bounded native BuildKit GC and daily dedicated CI Docker pruning";
      budget = lib.mkOption {
        type = lib.types.strMatching "[1-9][0-9]*(MiB|GiB|TiB)";
        default = "20GiB";
        description = ''
          Unused build cache GC target for the dedicated Docker daemon, not a
          hard disk quota. Active build data may exceed this target. Nested
          docker-container BuildKit builders require their own GC configuration;
          their cache volumes are preserved by the daily system prune.
        '';
      };
      unusedAge = lib.mkOption {
        type = lib.types.strMatching "[1-9][0-9]*h";
        default = "48h";
        description = ''
          Prefer build cache unused for this duration during native GC, then
          reclaim other eligible unused cache above the budget. Also used as
          the daily system prune age filter. For images and stopped containers,
          Docker measures creation age, not time since last use. Live containers
          and volumes are preserved.
        '';
      };
    };
  };

  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = cfg.resourcePolicy.enable;
        message = "Isolated runner Docker requires the aggregate resource policy.";
      }
      {
        assertion = cfg.dockerHost == "unix://${runtimeDir}/docker.sock";
        message = "Isolated runner Docker requires its dedicated socket.";
      }
    ];
    services.forgejo-actions-runner.resourcePolicy.enable = lib.mkDefault true;
    users.users.forgejo-builder = {
      isSystemUser = true;
      group = "forgejo-runner";
      home = stateDir;
      autoSubUidGidRange = true;
    };
    systemd.services.forgejo-runner-docker = {
      description = "Dedicated rootless Forgejo build daemon";
      requires = ["forgejo-runner-resource-policy.service"];
      after = ["network-online.target" "forgejo-runner-resource-policy.service"];
      restartIfChanged = false;
      wants = ["network-online.target"];
      path = ["/run/wrappers"];
      environment = {
        HOME = stateDir;
        XDG_RUNTIME_DIR = runtimeDir;
      };
      serviceConfig = {
        Type = "notify";
        User = "forgejo-builder";
        Group = "forgejo-runner";
        StateDirectory = "forgejo-docker";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "forgejo-docker";
        RuntimeDirectoryMode = "0750";
        ExecStart = "${pkgs.docker}/bin/dockerd-rootless --config-file=${daemonConfig}";
        ExecCondition = "+${lib.getExe apiStartGate}";
        # A rootless daemon reads per-host CAs only from
        # $XDG_CONFIG_HOME/docker/certs.d, here $HOME/.config/docker/certs.d
        # (CertsDir in moby v29 daemon/pkg/registry), never /etc/docker/certs.d.
        # Rewriting it at each start, after the state mount is up, keeps
        # XDG_CONFIG_HOME and the rest of the daemon's state where they are
        # and drops a CA that is no longer configured.
        ExecStartPre = "${mirrorCaSetup "forgejo-docker-mirror-ca" dockerCertsDir}";
        Slice = "forgejobuilds.slice";
        Delegate = true;
        NotifyAccess = "all";
        Restart = "no";
        TimeoutStartSec = "120s";
        TimeoutStopSec = "90s";
        KillMode = "mixed";
        # A descendant OOM kill must not make systemd stop the whole service.
        # Kernel victim selection still applies within the shared memory budget.
        OOMPolicy = "continue";
        LimitNOFILE = 1048576;
        LimitNPROC = "infinity";
        LimitCORE = 0;
      };
    };
    systemd.services.forgejo-actions-runner = {
      # The stop signals only the runner, which stops polling and waits for
      # its running jobs up to its shutdown timeout before it cancels them.
      serviceConfig.KillMode = "mixed";
      wants = ["forgejo-runner-hold.service"];
      after = ["forgejo-runner-hold.service"];
      restartIfChanged = false;
      environment =
        cfg.runnerHold.gateEnvironment
        // {
          RUNNER_UNIT = "forgejo-actions-runner.service";
        };
      # The hold state is root-only; only this fixed condition command runs
      # as root. A skipped start must not trigger Restart=on-failure.
      serviceConfig.ExecCondition = "+${lib.getExe cfg.runnerHold.gate}";
    };
    systemd.services.forgejo-runner-cache-prune = {
      description = "Prune unused dedicated CI Docker cache and images";
      after = ["forgejo-runner-docker.service"];
      requires = ["forgejo-runner-docker.service"];
      environment.DOCKER_HOST = cfg.dockerHost;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.docker}/bin/docker system prune --force --all --filter=until=${pruneAge}";
      };
    };
    systemd.timers.forgejo-runner-cache-prune = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar =
          if retention.enable
          then "daily"
          else "weekly";
        RandomizedDelaySec = "6h";
        Persistent = true;
      };
    };
    # Pressure pruning follows the dedicated daemon, so build cache left in the
    # host daemon by earlier CI or manual builds is otherwise never reclaimed.
    # Tagged images, containers and volumes stay untouched for host workloads.
    systemd.services.host-docker-cache-prune = lib.mkIf config.virtualisation.docker.enable {
      description = "Prune stale host Docker build cache and dangling images";
      after = ["docker.service"];
      requires = ["docker.service"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = [
          "${config.virtualisation.docker.package}/bin/docker builder prune --all --force --filter until=168h"
          "${config.virtualisation.docker.package}/bin/docker image prune --force"
        ];
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };
    systemd.timers.host-docker-cache-prune = lib.mkIf config.virtualisation.docker.enable {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "weekly";
        RandomizedDelaySec = "6h";
        Persistent = true;
      };
    };
  };
}
