{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.forgejo-actions-runner;
  enabled = cfg.enable && cfg.isolatedDocker.enable;
  stateDir = "/var/lib/forgejo-docker";
  runtimeDir = "/run/forgejo-docker";
  daemonConfig = (pkgs.formats.json {}).generate "forgejo-docker.json" {
    hosts = ["unix://${runtimeDir}/docker.sock"];
    "data-root" = "${stateDir}/overlay2";
    "exec-root" = "${runtimeDir}/exec";
    pidfile = "${runtimeDir}/docker.pid";
    group = "root"; # Root inside the user namespace maps to the service's group.
    "storage-driver" = "overlay2";
    "exec-opts" = ["native.cgroupdriver=cgroupfs"];
  };
  guard = pkgs.writeShellApplication {
    name = "forgejo-runner-aggregate-pressure-guard";
    runtimeInputs = with pkgs; [coreutils gawk systemd util-linux];
    text = builtins.readFile ./aggregate-pressure-guard.sh;
  };
in {
  options.services.forgejo-actions-runner.isolatedDocker.enable =
    lib.mkEnableOption "experimental dedicated rootless CI Docker daemon (requires qualification before activation)";

  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = cfg.resourcePolicy.enable && cfg.ioPressureGuard.enable;
        message = "Isolated runner Docker requires aggregate resource policy and pressure guard.";
      }
      {
        assertion = cfg.dockerHost == "unix://${runtimeDir}/docker.sock";
        message = "Isolated runner Docker requires its dedicated socket.";
      }
    ];
    services.forgejo-actions-runner = {
      resourcePolicy.enable = lib.mkDefault true;
      ioPressureGuard.enable = lib.mkDefault true;
    };
    users.users.forgejo-builder = {
      isSystemUser = true;
      group = "forgejo-runner";
      home = stateDir;
      autoSubUidGidRange = true;
    };
    systemd.services.forgejo-runner-docker = {
      description = "Dedicated rootless Forgejo build daemon";
      requires = ["forgejo-runner-resource-policy.service" "forgejo-runner-io-pressure-guard.service"];
      bindsTo = ["forgejo-runner-io-pressure-guard.service"];
      after = ["network-online.target" "forgejo-runner-resource-policy.service" "forgejo-runner-io-pressure-guard.service"];
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
        Slice = "forgejobuilds.slice";
        Delegate = true;
        NotifyAccess = "all";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStartSec = "120s";
        TimeoutStopSec = "90s";
        KillMode = "mixed";
        # A descendant OOM kill must not make systemd stop the whole service.
        # Kernel victim selection still applies within the shared memory budget.
        OOMPolicy = "continue";
        LimitNOFILE = "infinity";
        LimitNPROC = "infinity";
        LimitCORE = 0;
      };
    };
    systemd.services.forgejo-runner-io-pressure-guard = {
      description = "Freeze the dedicated CI build aggregate under I/O pressure";
      # Watch the slice before admitting daemon workers. Losing the guard stops
      # the daemon and its descendants, including jobs not owned by the runner.
      requires = ["forgejo-runner-resource-policy.service"];
      after = ["forgejo-runner-resource-policy.service"];
      environment = {
        HIGH_THRESHOLD_HUNDREDTHS = toString (cfg.ioPressureGuard.highPercent * 100);
        LOW_THRESHOLD_HUNDREDTHS = toString (cfg.ioPressureGuard.lowPercent * 100);
        HIGH_SAMPLES_REQUIRED = toString (cfg.ioPressureGuard.highDurationSeconds / cfg.ioPressureGuard.sampleSeconds + 1);
        LOW_SAMPLES_REQUIRED = toString (cfg.ioPressureGuard.lowDurationSeconds / cfg.ioPressureGuard.sampleSeconds + 1);
        SAMPLE_SECONDS = toString cfg.ioPressureGuard.sampleSeconds;
        TRANSITION_TIMEOUT_SECONDS = toString cfg.ioPressureGuard.transitionTimeoutSeconds;
      };
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        ExecStart = lib.getExe guard;
        RuntimeDirectory = "forgejo-runner-aggregate-pressure";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = "yes";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
    systemd.services.forgejo-runner-cache-pressure-prune = lib.mkIf cfg.cachePressure.enable {
      after = ["forgejo-runner-io-pressure-guard.service"];
      requires = ["forgejo-runner-io-pressure-guard.service"];
    };
    systemd.services.forgejo-runner-cache-prune = {
      description = "Prune unused dedicated CI Docker cache and images";
      after = ["forgejo-runner-io-pressure-guard.service"];
      requires = ["forgejo-runner-io-pressure-guard.service"];
      environment.DOCKER_HOST = cfg.dockerHost;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.docker}/bin/docker system prune --force --all --filter=until=168h";
      };
    };
    systemd.timers.forgejo-runner-cache-prune = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "weekly";
        RandomizedDelaySec = "6h";
        Persistent = true;
      };
    };
  };
}
