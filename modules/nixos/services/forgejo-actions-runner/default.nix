{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  cfg = config.services.forgejo-actions-runner;
  resourcePolicyCfg = cfg.resourcePolicy;
  isolated = cfg.isolatedDocker.enable;
  dockerService =
    if isolated
    then "forgejo-runner-docker.service"
    else "docker.service";
  dockerSocket = lib.removePrefix "unix://" cfg.dockerHost;

  settingsFormat = pkgs.formats.yaml {};
  stateDir = "/var/lib/forgejo/runner";
  runtimeDir = "/run/forgejo-runner";
  envFile = "${runtimeDir}/${cfg.name}.env";
  nameFile = "${stateDir}/.runner-name";
  pressureGuardLabel = "io.alc.forgejo-runner=${cfg.name}";

  secretName = key: "forgejo_runner_${key}";
  secretPath = key: "/run/secrets/${secretName key}";

  jobTimeout = "3600s";
  serviceStopTimeout = "3660s";

  secretKeys = lib.unique (["runner_token"] ++ lib.attrValues cfg.secretEnv);

  allEnvNames = lib.unique ((lib.attrNames cfg.jobEnv) ++ (lib.attrNames cfg.secretEnv));
  containerRuntimeOptions = lib.concatStringsSep " " (
    (map (name: "-e ${name}") allEnvNames)
    ++ cfg.containerOptions
    ++ lib.optional cfg.ioPressureGuard.enable "--label=${pressureGuardLabel}"
  );

  runnerConfig = settingsFormat.generate "forgejo-runner-config.yaml" {
    log.level = cfg.logLevel;
    runner = {
      file = ".runner";
      capacity = cfg.capacity;
      labels = cfg.labels;
      env_file = envFile;
      timeout = jobTimeout;
      shutdown_timeout = jobTimeout;
      insecure = false;
      fetch_timeout = "5s";
      fetch_interval = "2s";
    };
    container = {
      network = "";
      privileged = false;
      options = containerRuntimeOptions;
      workdir_parent = null;
      valid_volumes = [dockerSocket];
      docker_host = cfg.dockerHost;
      force_pull = false;
    };
    host.workdir_parent = "${stateDir}/host-work";
  };

  literalEnvScript = lib.concatLines (
    lib.mapAttrsToList (name: value: ''
      printf '%s=%s\n' ${lib.escapeShellArg name} ${lib.escapeShellArg value} >> "$env_tmp"
    '')
    cfg.jobEnv
  );

  secretEnvScript = lib.concatLines (
    lib.mapAttrsToList (name: key: ''
      printf '%s=' ${lib.escapeShellArg name} >> "$env_tmp"
      ${pkgs.coreutils}/bin/tr -d '\n' < ${lib.escapeShellArg (secretPath key)} >> "$env_tmp"
      printf '\n' >> "$env_tmp"
    '')
    cfg.secretEnv
  );

  secretChecksScript = lib.concatLines (
    map (key: ''
      test -s ${lib.escapeShellArg (secretPath key)}
    '')
    secretKeys
  );

  labelsWanted = lib.concatStringsSep "," cfg.labels;

  resourcePolicyApply = pkgs.writeShellApplication {
    name = "forgejo-runner-resource-policy-apply";
    runtimeInputs = [
      pkgs.glibc.bin
      pkgs.systemd
    ];
    text = ''
      set -euo pipefail

      getconf_command="''${FORGEJO_RUNNER_GETCONF:-getconf}"
      systemctl_command="''${FORGEJO_RUNNER_SYSTEMCTL:-systemctl}"
      online_processors="$("$getconf_command" _NPROCESSORS_ONLN)"

      case "$online_processors" in
        "" | *[!0-9]*)
          echo "getconf returned an invalid online processor count: $online_processors" >&2
          exit 1
          ;;
      esac
      if ((online_processors < 1)); then
        echo "getconf returned no online processors" >&2
        exit 1
      fi

      quota_percent=$((online_processors * ${toString resourcePolicyCfg.cpuQuotaPercent}))
      exec "$systemctl_command" set-property --runtime forgejobuilds.slice \
        "CPUQuota=''${quota_percent}%"
    '';
  };

  cachePressurePrune = pkgs.writeShellApplication {
    name = "forgejo-runner-cache-pressure-prune";
    runtimeInputs = with pkgs; [
      coreutils
      docker
      gawk
      util-linux
    ];
    text = ''
      set -euo pipefail

      read -r filesystem_bytes used_percent < <(
        df --block-size=1 --output=size,pcent ${lib.escapeShellArg cfg.cachePressure.mountPoint} |
          awk 'NR == 2 { gsub(/%/, "", $2); print $1, $2 }'
      )

      if (( used_percent < ${toString cfg.cachePressure.triggerPercent} )); then
        exit 0
      fi

      target_free_bytes=$((filesystem_bytes * ${toString cfg.cachePressure.targetFreePercent} / 100))
      prune_args=(
        --all
        --force
        --min-free-space "''${target_free_bytes}B"
        --reserved-space ${lib.escapeShellArg cfg.cachePressure.reservedCacheSpace}
      )

      if (( used_percent < ${toString cfg.cachePressure.criticalPercent} )); then
        prune_args+=(--filter ${lib.escapeShellArg "until=${cfg.cachePressure.minUnusedAge}"})
        policy="cache unused for at least ${cfg.cachePressure.minUnusedAge}"
      else
        policy="all unused cache"
      fi

      logger -t forgejo-runner-cache-pressure-prune \
        "${cfg.cachePressure.mountPoint} is ''${used_percent}% full; pruning $policy toward ${toString cfg.cachePressure.targetFreePercent}% free"

      docker builder prune "''${prune_args[@]}"
    '';
  };
  ioPressureGuard = pkgs.writeShellApplication {
    name = "forgejo-runner-io-pressure-guard";
    runtimeInputs = with pkgs; [
      coreutils
      docker
      gawk
      systemd
      util-linux
    ];
    text = builtins.readFile ./io-pressure-guard.sh;
  };
  registerFromFile = pkgs.writeShellApplication {
    name = "forgejo-runner-register-from-file";
    runtimeInputs = [pkgs.coreutils];
    text = builtins.readFile ./register-from-file.sh;
  };
in {
  imports = [./isolated-docker.nix];

  options.services.forgejo-actions-runner = {
    enable = lib.mkEnableOption "native Forgejo Actions runner";

    package = lib.mkPackageOption pkgs "forgejo-runner" {};

    name = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Runner name registered with Forgejo.";
    };

    url = lib.mkOption {
      type = lib.types.str;
      default = "https://git.alc.xyz";
      description = "Forgejo instance URL.";
    };

    capacity = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Maximum number of concurrent jobs accepted by this runner.";
    };

    labels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Forgejo runner labels and execution backends.";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [
        "trace"
        "debug"
        "info"
        "warn"
        "error"
        "fatal"
      ];
      default = "info";
    };

    dockerHost = lib.mkOption {
      type = lib.types.str;
      default =
        if isolated
        then "unix:///run/forgejo-docker/docker.sock"
        else "unix:///var/run/docker.sock";
    };

    containerOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["--cpu-shares=512"];
      description = ''
        Additional Docker run options applied to every job, step, and service
        container created by Forgejo Runner. Containers created through the
        mounted Docker socket do not inherit these options.
      '';
    };

    resourcePolicy = {
      enable = lib.mkEnableOption "aggregate resource controls for Forgejo-created containers";

      cpuQuotaPercent = lib.mkOption {
        type = lib.types.ints.between 1 100;
        default = 50;
        description = ''
          Maximum aggregate CPU use as a percentage of the host's online
          logical processors. The systemd CPUQuota value is calculated when
          the runner starts so host processor counts stay out of configuration.
        '';
      };

      cpuWeight = lib.mkOption {
        type = lib.types.ints.between 1 10000;
        default = 10;
        description = "CPU scheduling weight used when the host is contended.";
      };

      ioWeight = lib.mkOption {
        type = lib.types.ints.between 1 10000;
        default = 10;
        description = ''
          Best-effort I/O scheduling weight. Buffered writeback requires
          filesystem cgroup-writeback support, which ZFS does not provide.
        '';
      };

      memoryHigh = lib.mkOption {
        type = lib.types.str;
        default = "40%";
        description = "Aggregate memory throttling threshold for runner containers.";
      };

      memoryMax = lib.mkOption {
        type = lib.types.str;
        default = "50%";
        description = "Aggregate hard memory limit for runner containers.";
      };
    };

    ioPressureGuard = {
      enable = lib.mkEnableOption "host I/O pressure guard for owned runner containers";

      highPercent = lib.mkOption {
        type = lib.types.ints.between 1 99;
        default = 20;
        description = "Full I/O PSI avg10 percentage that starts the high-pressure timer.";
      };

      lowPercent = lib.mkOption {
        type = lib.types.ints.between 0 98;
        default = 5;
        description = "Full I/O PSI avg10 percentage that starts the recovery timer.";
      };

      highDurationSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20;
        description = "Sustained high-pressure duration before owned containers are paused.";
      };

      lowDurationSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60;
        description = "Sustained low-pressure duration before the owned container batch is resumed.";
      };

      sampleSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "Interval between I/O PSI samples.";
      };

      dockerTimeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = "Deadline for each Docker API operation.";
      };

      transitionTimeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 120;
        description = "Deadline for aggregate freeze and thaw transitions.";
      };
    };

    secretsFile = lib.mkOption {
      type = lib.types.path;
      default = inputs.nix-secrets.secrets.files.integrations.forgejoRunner;
      description = "SOPS file containing Forgejo runner registration and job environment secrets.";
    };

    jobEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Literal environment values written to the runner job env file.";
    };

    secretEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Mapping from job env variable names to keys in the runner SOPS file.";
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        bash
        coreutils
        curl
        docker
        git
        gnugrep
        gnused
        gawk
      ];
      description = "Packages available to the runner process and explicit host-label jobs.";
    };

    cachePressure = {
      enable =
        lib.mkEnableOption "disk-pressure-aware Docker build-cache pruning"
        // {
          default = true;
        };

      mountPoint = lib.mkOption {
        type = lib.types.str;
        default = "/";
        description = "Filesystem whose usage triggers build-cache pruning.";
      };

      triggerPercent = lib.mkOption {
        type = lib.types.ints.between 1 99;
        default = 70;
        description = "Used-space percentage at which unused build cache is pruned.";
      };

      criticalPercent = lib.mkOption {
        type = lib.types.ints.between 1 99;
        default = 80;
        description = "Used-space percentage at which all unused build cache may be pruned regardless of age.";
      };

      minUnusedAge = lib.mkOption {
        type = lib.types.str;
        default = "48h";
        description = "Minimum cache age eligible for pruning below the critical threshold.";
      };

      targetFreePercent = lib.mkOption {
        type = lib.types.ints.between 1 99;
        default = 40;
        description = "Free-space percentage requested from BuildKit after pruning starts.";
      };

      reservedCacheSpace = lib.mkOption {
        type = lib.types.str;
        default = "10GB";
        description = "Minimum BuildKit cache space retained during pressure pruning.";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "15m";
        description = "Interval between inexpensive filesystem pressure checks.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.forgejo-actions-runner.containerOptions = lib.mkIf (resourcePolicyCfg.enable && !isolated) (lib.mkBefore [
      "--cgroup-parent=forgejobuilds.slice"
    ]);

    assertions = [
      {
        assertion = cfg.labels != [];
        message = "services.forgejo-actions-runner.labels must not be empty.";
      }
      {
        assertion = isolated || config.virtualisation.docker.enable;
        message = "services.forgejo-actions-runner requires Docker for docker:// labels.";
      }
      {
        assertion = cfg.cachePressure.targetFreePercent > 100 - cfg.cachePressure.triggerPercent;
        message = "services.forgejo-actions-runner.cachePressure.targetFreePercent must provide hysteresis beyond the trigger.";
      }
      {
        assertion = cfg.cachePressure.criticalPercent > cfg.cachePressure.triggerPercent;
        message = "services.forgejo-actions-runner.cachePressure.criticalPercent must exceed triggerPercent.";
      }
      {
        assertion = cfg.ioPressureGuard.lowPercent < cfg.ioPressureGuard.highPercent;
        message = "services.forgejo-actions-runner.ioPressureGuard.lowPercent must be below highPercent.";
      }
      {
        assertion = lib.mod cfg.ioPressureGuard.highDurationSeconds cfg.ioPressureGuard.sampleSeconds == 0;
        message = "services.forgejo-actions-runner.ioPressureGuard.highDurationSeconds must be divisible by sampleSeconds.";
      }
      {
        assertion = lib.mod cfg.ioPressureGuard.lowDurationSeconds cfg.ioPressureGuard.sampleSeconds == 0;
        message = "services.forgejo-actions-runner.ioPressureGuard.lowDurationSeconds must be divisible by sampleSeconds.";
      }
    ];

    users.groups.forgejo-runner = {};
    users.users.forgejo-runner = {
      isSystemUser = true;
      group = "forgejo-runner";
      extraGroups = lib.optional (!isolated) "docker";
    };

    # A shared host daemon may also own application and rollback images. Keep
    # one week of runner build cache and leave image lifecycle to its consumer.
    systemd.services.forgejo-runner-cache-prune = lib.mkIf (!isolated) {
      description = "Prune old unused Forgejo runner build cache";
      environment.DOCKER_HOST = cfg.dockerHost;
      after = [dockerService];
      requires = [dockerService];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.docker}/bin/docker builder prune --all --force --filter=until=168h --reserved-space ${lib.escapeShellArg cfg.cachePressure.reservedCacheSpace}";
      };
    };
    systemd.timers.forgejo-runner-cache-prune = lib.mkIf (!isolated) {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "weekly";
        RandomizedDelaySec = "6h";
        Persistent = true;
      };
    };
    virtualisation.docker.daemon.settings."exec-opts" = lib.mkIf (resourcePolicyCfg.enable && !isolated) [
      "native.cgroupdriver=systemd"
    ];

    systemd.services.forgejo-runner-cache-pressure-prune = lib.mkIf cfg.cachePressure.enable {
      description = "Prune Forgejo runner build cache under disk pressure";
      environment.DOCKER_HOST = cfg.dockerHost;
      after = [dockerService];
      requires = [dockerService];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe cachePressurePrune;
      };
    };

    systemd.slices.forgejobuilds = lib.mkIf resourcePolicyCfg.enable {
      description = "Aggregate Forgejo Actions build resources";
      sliceConfig = {
        CPUWeight = resourcePolicyCfg.cpuWeight;
        IOWeight = resourcePolicyCfg.ioWeight;
        MemoryHigh = resourcePolicyCfg.memoryHigh;
        MemoryMax = resourcePolicyCfg.memoryMax;
      };
    };

    systemd.services.forgejo-runner-resource-policy = lib.mkIf resourcePolicyCfg.enable {
      description = "Apply host-relative Forgejo runner resource limits";
      requires = ["forgejobuilds.slice"];
      after = ["forgejobuilds.slice"];
      before = ["forgejo-actions-runner.service"];
      partOf = lib.optional (!isolated) "forgejo-actions-runner.service";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe resourcePolicyApply;
      };
    };

    systemd.timers.forgejo-runner-cache-pressure-prune = lib.mkIf cfg.cachePressure.enable {
      description = "Check Forgejo runner build-cache disk pressure";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = cfg.cachePressure.interval;
        RandomizedDelaySec = "2m";
        Persistent = true;
      };
    };

    systemd.services.forgejo-runner-io-pressure-guard = lib.mkIf (cfg.ioPressureGuard.enable && !isolated) {
      description = "Pause owned Forgejo runner containers under sustained I/O pressure";
      after = [dockerService];
      requires = [dockerService];
      wantedBy = ["multi-user.target"];
      environment = {
        DOCKER_HOST = cfg.dockerHost;
        RUNNER_CONTAINER_LABEL = pressureGuardLabel;
        HIGH_THRESHOLD_HUNDREDTHS = toString (cfg.ioPressureGuard.highPercent * 100);
        LOW_THRESHOLD_HUNDREDTHS = toString (cfg.ioPressureGuard.lowPercent * 100);
        HIGH_SAMPLES_REQUIRED = toString (cfg.ioPressureGuard.highDurationSeconds / cfg.ioPressureGuard.sampleSeconds + 1);
        LOW_SAMPLES_REQUIRED = toString (cfg.ioPressureGuard.lowDurationSeconds / cfg.ioPressureGuard.sampleSeconds + 1);
        SAMPLE_SECONDS = toString cfg.ioPressureGuard.sampleSeconds;
        DOCKER_TIMEOUT_SECONDS = toString cfg.ioPressureGuard.dockerTimeoutSeconds;
      };
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        ExecStart = lib.getExe ioPressureGuard;
        Restart = "always";
        RestartSec = "2s";
        RuntimeDirectory = "forgejo-runner-pressure";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = "yes";
      };
    };

    sops.secrets = lib.listToAttrs (
      map (key: {
        name = secretName key;
        value = {
          sopsFile = cfg.secretsFile;
          key = key;
          path = secretPath key;
          owner = "forgejo-runner";
          group = "forgejo-runner";
          mode = "0400";
          restartUnits = ["forgejo-actions-runner.service"];
        };
      })
      secretKeys
    );

    systemd.tmpfiles.rules = [
      "d /var/lib/forgejo 0750 forgejo-runner forgejo-runner -"
      "d ${stateDir} 0750 forgejo-runner forgejo-runner -"
      "Z ${stateDir} 0750 forgejo-runner forgejo-runner -"
    ];

    systemd.services.forgejo-actions-runner = {
      description = "Forgejo Actions Runner (${cfg.name})";
      wants = ["network-online.target"];
      after =
        [
          "network-online.target"
          dockerService
        ]
        ++ lib.optionals resourcePolicyCfg.enable ["forgejo-runner-resource-policy.service"]
        ++ lib.optional cfg.ioPressureGuard.enable "forgejo-runner-io-pressure-guard.service";
      requires =
        [
          dockerService
        ]
        ++ lib.optionals resourcePolicyCfg.enable ["forgejo-runner-resource-policy.service"]
        ++ lib.optional cfg.ioPressureGuard.enable "forgejo-runner-io-pressure-guard.service";
      bindsTo = lib.optional cfg.ioPressureGuard.enable "forgejo-runner-io-pressure-guard.service";
      wantedBy = ["multi-user.target"];
      path = [cfg.package] ++ cfg.extraPackages;
      environment = {
        HOME = stateDir;
        DOCKER_HOST = cfg.dockerHost;
      };
      serviceConfig = {
        User = "forgejo-runner";
        Group = "forgejo-runner";
        SupplementaryGroups = lib.optional (!isolated) "docker";
        WorkingDirectory = stateDir;
        RuntimeDirectory = "forgejo-runner";
        RuntimeDirectoryMode = "0750";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStartSec = "90s";
        TimeoutStopSec = serviceStopTimeout;
        NoNewPrivileges = true;
      };
      preStart = ''
        set -euo pipefail

        test -S ${lib.escapeShellArg dockerSocket}
        docker version --format '{{.Server.Version}}' >/dev/null
        ${secretChecksScript}

        install -d -m 0750 ${lib.escapeShellArg stateDir}
        env_tmp="$(mktemp ${lib.escapeShellArg runtimeDir}/env.XXXXXX)"
        chmod 0600 "$env_tmp"
        ${literalEnvScript}
        ${secretEnvScript}
        mv "$env_tmp" ${lib.escapeShellArg envFile}

        ${lib.getExe registerFromFile} \
          ${lib.getExe cfg.package} \
          ${runnerConfig} \
          ${lib.escapeShellArg "${stateDir}/.runner"} \
          ${lib.escapeShellArg nameFile} \
          ${lib.escapeShellArg cfg.url} \
          ${lib.escapeShellArg cfg.name} \
          ${lib.escapeShellArg labelsWanted} \
          < ${lib.escapeShellArg (secretPath "runner_token")}
      '';
      script = ''
        exec forgejo-runner daemon --config ${runnerConfig}
      '';
    };
  };
}
