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
  diskSpaceEnvironment = {
    DISK_HELPER_FILE = "${./disk-space-admission.sh}";
    DISK_SPACE_ENABLED =
      if cfg.ioPressureGuard.diskSpace.enable
      then "1"
      else "0";
    DISK_SPACE_PATH = cfg.ioPressureGuard.diskSpace.path;
    DISK_DRAIN_BYTES = toString (cfg.ioPressureGuard.diskSpace.drainFreeGiB * 1024 * 1024 * 1024);
    DISK_DRAIN_PERCENT = toString cfg.ioPressureGuard.diskSpace.drainFreePercent;
    DISK_CRITICAL_BYTES = toString (cfg.ioPressureGuard.diskSpace.criticalFreeGiB * 1024 * 1024 * 1024);
    DISK_CRITICAL_PERCENT = toString cfg.ioPressureGuard.diskSpace.criticalFreePercent;
    DISK_RECOVERY_BYTES = toString (cfg.ioPressureGuard.diskSpace.recoveryFreeGiB * 1024 * 1024 * 1024);
    DISK_RECOVERY_PERCENT = toString cfg.ioPressureGuard.diskSpace.recoveryFreePercent;
  };
  settingsFormat = pkgs.formats.yaml {};
  labelName = label: builtins.head (lib.splitString ":" label);
  labelNames = labels: map labelName labels;
  validLabels = labels:
    labels
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
    labels;
  uniqueLabelNames = labels: builtins.length (lib.unique (labelNames labels)) == builtins.length labels;

  # Every Podman runner unit shares the one Podman API, pressure guard,
  # lifecycle boundary and build slice, and runs as the one runner account.
  # Each has its own registration, state and runtime directories. The
  # existing runner keeps its unit, paths and configuration file name, so
  # its Forgejo identity survives; extra runners derive theirs from their
  # attribute name.
  mkInstance = {
    serviceName,
    description,
    labels,
    capacity,
    name,
    registrationTokenFile,
  }: rec {
    inherit serviceName description labels capacity name registrationTokenFile;
    unit = "${serviceName}.service";
    state = "/var/lib/${serviceName}";
    runtime = "/run/${serviceName}";
    envFile = "${runtime}/job.env";
    config = settingsFormat.generate "${serviceName}.yaml" {
      log.level = canary.logLevel;
      runner = {
        file = ".runner";
        inherit capacity labels;
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
      host.workdir_parent = "${state}/host-work";
    };
  };
  canaryInstance = mkInstance {
    serviceName = "forgejo-podman-runner";
    description = "Forgejo Podman canary runner (${canary.name})";
    inherit (canary) labels capacity name registrationTokenFile;
  };
  # attrNames order: extra runners follow the existing one, sorted by name.
  extraInstances = lib.mapAttrsToList (key: extra:
    mkInstance {
      serviceName = "forgejo-podman-runner-${key}";
      description = "Forgejo Podman runner ${key} (${extra.name})";
      inherit (extra) labels capacity name registrationTokenFile;
    })
  canary.extraRunners;
  instances = [canaryInstance] ++ extraInstances;
  podmanLabels = lib.concatMap (instance: instance.labels) instances;
  # A label name served by more than one Podman runner must be listed in
  # sharedLabels and carry the same image on each of them.
  labelOverlapAllowed = name: let
    labels = builtins.filter (label: labelName label == name) podmanLabels;
  in
    builtins.length labels
    <= 1
    || (builtins.elem name canary.sharedLabels && builtins.length (lib.unique labels) == 1);
  registerFromFile = pkgs.writeShellApplication {
    name = "forgejo-podman-register-from-file";
    runtimeInputs = [pkgs.coreutils];
    text = builtins.readFile ./register-from-file.sh;
  };
  runnerStartGate = pkgs.writeShellApplication {
    name = "forgejo-podman-runner-start-gate";
    runtimeInputs = with pkgs; [
      coreutils
      procps
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
  containersConf = pkgs.writeText "forgejo-podman-containers.conf" ''
    [containers]
    dns_servers = [${lib.concatMapStringsSep ", " builtins.toJSON canary.dnsServers}]
  '';
  literalEnvScript = lib.concatLines (
    lib.mapAttrsToList (name: value: ''
      printf '%s=%s\n' ${lib.escapeShellArg name} ${lib.escapeShellArg value} >> "$env_tmp"
    '')
    canary.jobEnv
  );
  runnerService = instance: {
    inherit (instance) description;
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
    environment =
      diskSpaceEnvironment
      // {
        HOME = instance.state;
        DOCKER_HOST = "unix://${socketPath}";
        RUNNER_UNIT = instance.unit;
        RUNNER_UNITS = lib.concatStringsSep " " cfg.runnerUnits;
        GAME_HELPER_FILE = "${./game-admission.sh}";
        GAME_ADMISSION_ENABLED =
          if cfg.ioPressureGuard.admissionControl.gameProcess.enable
          then "1"
          else "0";
        GAME_USER = cfg.ioPressureGuard.admissionControl.gameProcess.user;
        GAME_ARGV0_BASENAMES = lib.concatStringsSep " " cfg.ioPressureGuard.admissionControl.gameProcess.argv0Basenames;
        GAME_COOLDOWN_SECONDS = toString cfg.ioPressureGuard.admissionControl.gameProcess.cooldownSeconds;
      };
    serviceConfig = {
      User = "forgejo-podman-runner";
      Group = "forgejo-podman";
      WorkingDirectory = instance.state;
      RuntimeDirectory = instance.serviceName;
      RuntimeDirectoryMode = "0750";
      # Retry transient runner process failures only. ExecCondition still
      # gates each start on drain ownership, game admission and guard health.
      Restart = "on-failure";
      RestartSec = "30s";
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
      test -s ${lib.escapeShellArg instance.registrationTokenFile}

      env_tmp="$(mktemp ${lib.escapeShellArg instance.runtime}/env.XXXXXX)"
      chmod 0600 "$env_tmp"
      ${literalEnvScript}
      mv "$env_tmp" ${lib.escapeShellArg instance.envFile}

      ${lib.getExe registerFromFile} \
        ${lib.getExe canary.package} \
        ${instance.config} \
        ${lib.escapeShellArg "${instance.state}/.runner"} \
        ${lib.escapeShellArg "${instance.state}/.runner-name"} \
        ${lib.escapeShellArg canary.url} \
        ${lib.escapeShellArg instance.name} \
        ${lib.escapeShellArg (lib.concatStringsSep "," instance.labels)} \
        < ${lib.escapeShellArg instance.registrationTokenFile}
    '';
    script = ''
      exec forgejo-runner daemon --config ${instance.config}
    '';
  };
in {
  options.services.forgejo-actions-runner.runnerUnits = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    internal = true;
    default =
      ["forgejo-actions-runner.service"]
      ++ lib.optionals canary.enable (map (instance: instance.unit) instances);
    description = ''
      Runner units sharing the dedicated CI aggregate: the primary Docker
      runner first, then the existing Podman runner, then extra Podman runners
      sorted by name. The pressure guard, start gates, lifecycle teardown, idle
      cleanup and fence recovery all take this list.
    '';
  };

  options.services.forgejo-actions-runner.podmanCanary = {
    enable = lib.mkEnableOption "separate, qualified rootless Podman CI canary";
    storageRoot = lib.mkOption {
      type = lib.types.str;
      default = "${builderState}/storage";
      readOnly = true;
      internal = true;
      description = "Podman image and container store of the canary API service.";
    };
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
      default = cfg.capacity;
      defaultText = lib.literalExpression "config.services.forgejo-actions-runner.capacity";
      description = "Concurrent jobs of the Podman runner; follows the Docker runner by default.";
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
    dnsServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["192.0.2.53"];
      description = ''
        Upstream resolvers for job containers. Aardvark forwards container
        lookups to these instead of the host's resolv.conf; empty keeps the
        host's resolvers.
      '';
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
    extraRunners = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
        options = {
          labels = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Labels with execution backends, such as ci-fast:docker://image.";
          };
          capacity = lib.mkOption {
            type = lib.types.ints.positive;
            default = 1;
            description = "Concurrent jobs of this runner, within the shared build slice.";
          };
          name = lib.mkOption {
            type = lib.types.str;
            default = "${config.networking.hostName}-${name}";
            defaultText = lib.literalExpression ''"''${config.networking.hostName}-<name>"'';
            description = "Distinct Forgejo registration name of this runner.";
          };
          registrationTokenFile = lib.mkOption {
            type = lib.types.str;
            default = canary.registrationTokenFile;
            defaultText = lib.literalExpression "config.services.forgejo-actions-runner.podmanCanary.registrationTokenFile";
            description = "Absolute path to an activated registration token file; the canary's by default.";
          };
        };
      }));
      default = {};
      example = lib.literalExpression ''
        {
          fast = {
            labels = ["ci-fast:docker://docker.io/library/docker:27-cli"];
            capacity = 1;
          };
        }
      '';
      description = ''
        Additional Podman runner units. Entry `<name>` becomes
        `forgejo-podman-runner-<name>.service` with its own Forgejo
        registration and state, run by the canary's runner account against the
        same Podman API. Every runner shares the one pressure guard, lifecycle
        boundary and build slice, so the slice's budget is split across all of
        their jobs. Adding or removing an entry changes the guard's runner
        registry, which takes effect only after a reboot.
      '';
    };
    sharedLabels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["ci-fast"];
      description = ''
        Label names that more than one Podman runner may serve, such as a
        label a dedicated extra runner serves while the canary keeps it as
        overflow. A shared label must name the same image on every Podman
        runner that serves it. The Docker runner never shares a label.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.enable && !canary.enable) {
      assertions = [
        {
          assertion = canary.extraRunners == {};
          message = "Extra Podman runners require the Podman CI canary.";
        }
      ];
    })
    (lib.mkIf enabled {
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
          assertion = validLabels canary.labels;
          message = "Podman CI canary requires explicit name:docker://image labels.";
        }
        {
          assertion = lib.intersectLists (labelNames canary.labels) (labelNames cfg.labels) == [];
          message = "Podman CI canary label names must not overlap Docker runner label names.";
        }
        {
          assertion = uniqueLabelNames canary.labels;
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
        {
          assertion = lib.all (key: builtins.match "[a-z0-9-]+" key != null) (lib.attrNames canary.extraRunners);
          message = "Extra Podman runner names must match ^[a-z0-9-]+$.";
        }
        {
          assertion = lib.all (instance: validLabels instance.labels && uniqueLabelNames instance.labels) extraInstances;
          message = "Extra Podman runners require unique, explicit name:docker://image labels.";
        }
        {
          # Docker and Podman runners run jobs on different engines; a job
          # must never land on either one by the same label.
          assertion = lib.intersectLists (labelNames podmanLabels ++ canary.sharedLabels) (labelNames cfg.labels) == [];
          message = "Podman runner label names, shared ones included, must not overlap Docker runner label names.";
        }
        {
          assertion = lib.all labelOverlapAllowed (lib.unique (labelNames podmanLabels));
          message = "A label name served by more than one Podman runner must be listed in podmanCanary.sharedLabels and name the same image on each.";
        }
        {
          assertion = let
            names = [cfg.name] ++ map (instance: instance.name) instances;
          in
            builtins.length (lib.unique names) == builtins.length names;
          message = "Docker and Podman runner registration names must be distinct.";
        }
        {
          assertion = builtins.length (lib.unique cfg.runnerUnits) == builtins.length cfg.runnerUnits;
          message = "Runner unit names must be distinct.";
        }
        {
          assertion = lib.all (instance: lib.hasPrefix "/" instance.registrationTokenFile) extraInstances;
          message = "Extra Podman runners require an absolute registrationTokenFile path.";
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
      systemd.tmpfiles.rules =
        lib.concatMap (instance: [
          "d ${instance.state} 0750 forgejo-podman-runner forgejo-podman -"
          "Z ${instance.state} 0750 forgejo-podman-runner forgejo-podman -"
        ])
        instances;

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
          RUNNER_UNITS = lib.concatStringsSep " " cfg.runnerUnits;
          CONTAINERS_CONF_OVERRIDE = lib.mkIf (canary.dnsServers != []) "${containersConf}";
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
          ExecStart = "${pkgs.podman}/bin/podman --remote=false --cgroup-manager=cgroupfs --storage-driver=overlay --root=${canary.storageRoot} --runroot=${builderRuntime}/storage system service --time=0";
        };
      };

      services.nixfleet-boot-check.runnerUnits =
        map (instance: {
          inherit (instance) unit;
          holdMarkerDirectory = "/run/forgejo-runner-aggregate-pressure/runners/${instance.unit}";
        })
        instances;
    })
    (lib.mkIf enabled {
      systemd.services = lib.listToAttrs (map (instance: lib.nameValuePair instance.serviceName (runnerService instance)) instances);
    })
  ];
}
