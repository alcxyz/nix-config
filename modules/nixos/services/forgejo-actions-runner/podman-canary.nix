{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.forgejo-actions-runner;
  canary = cfg.podmanCanary;
  enabled = cfg.enable && canary.enable;
  apiUnit = "forgejo-runner-podman.service";
  socketUnit = "forgejo-runner-podman.socket";
  guardUnit = "forgejo-runner-io-pressure-guard.service";
  policyUnit = "forgejo-runner-resource-policy.service";
  lifecycleUnit = "forgejo-runner-aggregate-lifecycle.service";
  runnerUnit = "forgejo-podman-runner.service";
  builderState = "/var/lib/forgejo-podman";
  builderRuntime = "/run/forgejo-podman";
  socketPath = "${builderRuntime}/podman.sock";
  runnerState = "/var/lib/forgejo-podman-runner";
  runnerRuntime = "/run/forgejo-podman-runner";
  envFile = "${runnerRuntime}/job.env";
  settingsFormat = pkgs.formats.yaml {};
  labelName = label: builtins.head (lib.splitString ":" label);
  runnerConfig = settingsFormat.generate "forgejo-podman-runner.yaml" {
    log.level = canary.logLevel;
    runner = {
      file = ".runner";
      capacity = canary.capacity;
      labels = canary.labels;
      env_file = envFile;
      timeout = "3600s";
      shutdown_timeout = "3600s";
      insecure = false;
      fetch_timeout = "5s";
      fetch_interval = "2s";
    };
    container = {
      network = "";
      privileged = false;
      options = lib.concatStringsSep " " (map (name: "-e ${name}") (lib.attrNames canary.jobEnv));
      workdir_parent = null;
      valid_volumes = [socketPath];
      docker_host = "unix://${socketPath}";
      force_pull = false;
    };
    host.workdir_parent = "${runnerState}/host-work";
  };
  registerFromFile = pkgs.writeShellApplication {
    name = "forgejo-podman-register-from-file";
    runtimeInputs = [pkgs.coreutils];
    text = builtins.readFile ./register-from-file.sh;
  };
  runnerStartGate = pkgs.writeShellApplication {
    name = "forgejo-podman-runner-start-gate";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
      util-linux
    ];
    text = builtins.readFile ./runner-start-gate.sh;
  };
  apiStartGate = pkgs.writeShellApplication {
    name = "forgejo-podman-api-start-gate";
    runtimeInputs = with pkgs; [coreutils systemd util-linux];
    text = builtins.readFile ./podman-api-start-gate.sh;
  };
  lifecycleReady = pkgs.writeShellApplication {
    name = "forgejo-podman-lifecycle-ready";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
    ];
    text = ''
      deadline=$((SECONDS + 60))
      while ((remaining = deadline - SECONDS, remaining > 0)); do
        attempt_timeout=5
        ((remaining < attempt_timeout)) && attempt_timeout=$remaining
        if timeout --foreground "''${attempt_timeout}s" systemctl is-active --quiet ${lifecycleUnit}; then
          exit 0
        fi
        sleep 1
      done
      echo "dedicated aggregate lifecycle did not become active" >&2
      exit 1
    '';
  };
  literalEnvScript = lib.concatLines (
    lib.mapAttrsToList (name: value: ''
      printf '%s=%s\n' ${lib.escapeShellArg name} ${lib.escapeShellArg value} >> "$env_tmp"
    '')
    canary.jobEnv
  );
in {
  options.services.forgejo-actions-runner.podmanCanary = {
    enable = lib.mkEnableOption "separate, qualified rootless Podman CI canary";
    package = lib.mkOption {
      type = lib.types.package;
      default = cfg.package;
      description = "Runner package for the canary, independently qualified from the Docker runner.";
    };
    name = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.name}-podman";
      description = "Distinct Forgejo registration name for the Podman canary.";
    };
    url = lib.mkOption {
      type = lib.types.str;
      default = cfg.url;
      description = "Forgejo URL used to register the Podman canary.";
    };
    labels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Exclusive canary labels with execution backends, such as canary:docker://image.";
    };
    registrationTokenFile = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Absolute path to an activated registration token file; no token material is stored in this module.";
    };
    capacity = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
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
      default = cfg.logLevel;
    };
    jobEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Literal canary job environment. Existing runner job secrets are never inherited.";
    };
    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        bash
        coreutils
        curl
        docker
        docker-buildx
        git
        gnugrep
        gnused
        gawk
      ];
      description = "Packages available to the Podman runner process.";
    };
  };

  config = lib.mkIf enabled {
    assertions = [
      {
        assertion =
          cfg.isolatedDocker.enable
          && cfg.resourcePolicy.enable
          && cfg.ioPressureGuard.enable
          && cfg.ioPressureGuard.admissionControl.enable;
        message = "Podman CI canary requires isolated Docker, aggregate resource policy, pressure guard, and admission control.";
      }
      {
        assertion =
          canary.labels
          != []
          && lib.all (
            label: let
              parts = lib.splitString ":docker://" label;
            in
              builtins.length parts
              == 2
              && lib.all (part: part != "") parts
              && !(lib.hasInfix ":" (builtins.head parts))
          )
          canary.labels;
        message = "Podman CI canary requires explicit name:docker://image labels.";
      }
      {
        assertion = lib.intersectLists (map labelName canary.labels) (map labelName cfg.labels) == [];
        message = "Podman CI canary label names must not overlap Docker runner label names.";
      }
      {
        assertion =
          builtins.length (lib.unique (map labelName canary.labels))
          == builtins.length canary.labels;
        message = "Podman CI canary label names must be unique.";
      }
      {
        assertion = canary.name != cfg.name;
        message = "Podman CI canary registration name must differ from the Docker runner name.";
      }
      {
        assertion = lib.hasPrefix "/" canary.registrationTokenFile;
        message = "Podman CI canary requires an absolute registrationTokenFile path.";
      }
    ];

    virtualisation.containers.enable = true;

    users.groups.forgejo-podman = {};
    users.users.forgejo-podman-builder = {
      isSystemUser = true;
      group = "forgejo-podman";
      home = builderState;
      autoSubUidGidRange = true;
    };
    users.users.forgejo-podman-runner = {
      isSystemUser = true;
      group = "forgejo-podman";
      home = runnerState;
    };
    systemd.tmpfiles.rules = [
      "d ${runnerState} 0750 forgejo-podman-runner forgejo-podman -"
      "Z ${runnerState} 0750 forgejo-podman-runner forgejo-podman -"
    ];

    # This socket is pulled in by the API service. Stopping that service,
    # guard, or lifecycle also closes the listener so a late client cannot
    # reactivate workers after aggregate teardown.
    systemd.sockets.forgejo-runner-podman = {
      requires = [
        guardUnit
        policyUnit
      ];
      bindsTo = [
        guardUnit
        apiUnit
      ];
      after = [
        guardUnit
        policyUnit
      ];
      partOf = [
        apiUnit
        lifecycleUnit
      ];
      unitConfig = {
        # The guard must start before the listener. The default socket
        # sockets.target dependency would reverse that order through
        # basic.target and create a boot transaction cycle.
        DefaultDependencies = false;
        Before = ["shutdown.target"];
        Conflicts = ["shutdown.target"];
        ConditionPathExists = "/run/forgejo-runner-aggregate-pressure/runners/${runnerUnit}";
      };
      socketConfig = {
        ListenStream = socketPath;
        DirectoryMode = "0755";
        SocketUser = "forgejo-podman-builder";
        SocketGroup = "forgejo-podman";
        SocketMode = "0660";
        RemoveOnStop = true;
      };
    };

    systemd.services.forgejo-runner-podman = {
      description = "Dedicated rootless Podman CI API";
      wantedBy = ["multi-user.target"];
      requires = [
        socketUnit
        policyUnit
        guardUnit
        lifecycleUnit
      ];
      bindsTo = [guardUnit];
      after = [
        "network-online.target"
        socketUnit
        policyUnit
        guardUnit
      ];
      wants = ["network-online.target"];
      restartIfChanged = false;
      path = [
        pkgs.podman
        pkgs.slirp4netns
        pkgs.fuse-overlayfs
        "/run/wrappers"
      ];
      environment = {
        HOME = builderState;
        XDG_RUNTIME_DIR = builderRuntime;
        RUNNER_UNITS = "forgejo-actions-runner.service ${runnerUnit}";
        # Netavark must spawn DNS inside this delegated service. systemd-run
        # would create a user scope outside the aggregate resource boundary.
        PATH = lib.mkForce (
          lib.makeBinPath [
            pkgs.podman
            pkgs.slirp4netns
            pkgs.fuse-overlayfs
            pkgs.passt
            pkgs.coreutils
            pkgs.util-linux
          ]
          + ":/run/wrappers/bin"
        );
      };
      serviceConfig = {
        Type = "exec";
        User = "forgejo-podman-builder";
        Group = "forgejo-podman";
        StateDirectory = "forgejo-podman";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "forgejo-podman";
        RuntimeDirectoryMode = "0755";
        UMask = "0007";
        Slice = "forgejobuilds.slice";
        Delegate = true;
        KillMode = "control-group";
        OOMPolicy = "continue";
        Restart = "no";
        TimeoutStartSec = "120s";
        TimeoutStopSec = "90s";
        LimitCORE = 0;
        ExecCondition = "+${lib.getExe apiStartGate}";
        ExecStart = "${pkgs.podman}/bin/podman --remote=false --cgroup-manager=cgroupfs --storage-driver=overlay --root=${builderState}/storage --runroot=${builderRuntime}/storage system service --time=0";
      };
    };

    systemd.services.forgejo-podman-runner = {
      description = "Forgejo Podman canary runner (${canary.name})";
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"];
      requires = [
        apiUnit
        lifecycleUnit
      ];
      bindsTo = [guardUnit];
      after = [
        "network-online.target"
        apiUnit
        guardUnit
      ];
      restartIfChanged = false;
      path = [canary.package] ++ canary.extraPackages;
      environment = {
        HOME = runnerState;
        DOCKER_HOST = "unix://${socketPath}";
        RUNNER_UNIT = runnerUnit;
        RUNNER_UNITS = "forgejo-actions-runner.service ${runnerUnit}";
      };
      serviceConfig = {
        User = "forgejo-podman-runner";
        Group = "forgejo-podman";
        WorkingDirectory = runnerState;
        RuntimeDirectory = "forgejo-podman-runner";
        RuntimeDirectoryMode = "0750";
        Restart = "no";
        TimeoutStartSec = "90s";
        TimeoutStopSec = "3660s";
        KillMode = "mixed";
        NoNewPrivileges = true;
        ExecCondition = "+${lib.getExe runnerStartGate}";
        ExecStartPre = [(lib.getExe lifecycleReady)];
      };
      preStart = ''
        set -euo pipefail
        test -S ${lib.escapeShellArg socketPath}
        docker version --format '{{.Server.Version}}' >/dev/null
        test -s ${lib.escapeShellArg canary.registrationTokenFile}

        env_tmp="$(mktemp ${lib.escapeShellArg runnerRuntime}/env.XXXXXX)"
        chmod 0600 "$env_tmp"
        ${literalEnvScript}
        mv "$env_tmp" ${lib.escapeShellArg envFile}

        ${lib.getExe registerFromFile} \
          ${lib.getExe canary.package} \
          ${runnerConfig} \
          ${lib.escapeShellArg "${runnerState}/.runner"} \
          ${lib.escapeShellArg "${runnerState}/.runner-name"} \
          ${lib.escapeShellArg canary.url} \
          ${lib.escapeShellArg canary.name} \
          ${lib.escapeShellArg (lib.concatStringsSep "," canary.labels)} \
          < ${lib.escapeShellArg canary.registrationTokenFile}
      '';
      script = ''
        exec forgejo-runner daemon --config ${runnerConfig}
      '';
    };
  };
}
