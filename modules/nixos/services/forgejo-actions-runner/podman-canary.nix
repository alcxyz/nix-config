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
  policyUnit = "forgejo-runner-resource-policy.service";
  holdUnit = "forgejo-runner-hold.service";
  builderState = "/var/lib/forgejo-podman";
  builderRuntime = "/run/forgejo-podman";
  socketPath = "${builderRuntime}/podman.sock";
  runnerState = "/var/lib/forgejo-podman-runner";
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

  # Every Podman runner unit shares the one Podman API, runner hold and build
  # slice, and runs as the one runner account.
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
    registrationScope,
  }: rec {
    inherit serviceName description labels capacity name registrationTokenFile registrationScope;
    unit = "${serviceName}.service";
    state = "/var/lib/${serviceName}";
    runtime = "/run/${serviceName}";
    envFile = "${runtime}/job.env";
    config = settingsFormat.generate "${serviceName}.yaml" {
      log.level = canary.logLevel;
      runner =
        {
          file = ".runner";
          inherit capacity labels;
          env_file = envFile;
          timeout = "3600s";
          shutdown_timeout = "${toString cfg.shutdownTimeoutSeconds}s";
          insecure = false;
          fetch_timeout = "5s";
          fetch_interval = "2s";
        }
        # Jobs substitute through the host's Nix cache proxy (ADR-0103).
        # Runner variables override workflow and job `env`, not step `env`.
        // lib.optionalAttrs cfg.nixCacheProxy.enable {
          envs.NIX_CONFIG = cfg.nixCacheProxy.jobNixConfig;
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
    inherit (canary) labels capacity name registrationTokenFile registrationScope;
  };
  # attrNames order: extra runners follow the existing one, sorted by name.
  extraInstances = lib.mapAttrsToList (key: extra:
    mkInstance {
      serviceName = "forgejo-podman-runner-${key}";
      description = "Forgejo Podman runner ${key} (${extra.name})";
      inherit (extra) labels capacity name registrationTokenFile registrationScope;
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
  # An owner token passes no scope, so registrations from before the option
  # keep their recorded identity and are not repeated.
  scopeArgument = instance:
    lib.optionalString (instance.registrationScope != "owner")
    " ${lib.escapeShellArg instance.registrationScope}";
  registerFromFile = pkgs.writeShellApplication {
    name = "forgejo-podman-register-from-file";
    runtimeInputs = [pkgs.coreutils];
    text = builtins.readFile ./register-from-file.sh;
  };
  apiStartGate = pkgs.writeShellApplication {
    name = "forgejo-podman-api-start-gate";
    runtimeInputs = with pkgs; [coreutils systemd util-linux];
    text = builtins.readFile ./podman-api-start-gate.sh;
  };
  containersConf = pkgs.writeText "forgejo-podman-containers.conf" ''
    [containers]
    dns_servers = [${lib.concatMapStringsSep ", " builtins.toJSON canary.dnsServers}]
  '';
  # The host's registries.conf with the cache as a docker.io mirror. Podman
  # tries mirrors in order and then docker.io itself. The service reads it
  # through CONTAINERS_REGISTRIES_CONF, which takes precedence over both the
  # system file and a per-user one, so other Podman users are unaffected.
  registrySettings = config.virtualisation.containers.registries.settings;
  mirrorCaSetup = import ./registry-mirror-ca.nix {inherit cfg lib pkgs;};
  isDockerHub = registry: (registry.prefix or registry.location or "") == "docker.io";
  hostRegistries = registrySettings.registry or [];
  mirroredRegistry = registry:
    if isDockerHub registry
    then registry // {mirror = (registry.mirror or []) ++ [{location = cfg.registryMirror;}];}
    else registry;
  registriesConf = (pkgs.formats.toml {}).generate "forgejo-podman-registries.conf" (registrySettings
    // {
      registry =
        map mirroredRegistry hostRegistries
        ++ lib.optional (!lib.any isDockerHub hostRegistries) {
          location = "docker.io";
          mirror = [{location = cfg.registryMirror;}];
        };
    });
  literalEnvScript = lib.concatLines (
    lib.mapAttrsToList (name: value: ''
      printf '%s=%s\n' ${lib.escapeShellArg name} ${lib.escapeShellArg value} >> "$env_tmp"
    '')
    canary.jobEnv
  );
  runnerService = instance: {
    inherit (instance) description;
    wantedBy = ["multi-user.target"];
    requires = [apiUnit];
    wants = ["network-online.target" holdUnit];
    after = [
      "network-online.target"
      apiUnit
      holdUnit
    ];
    restartIfChanged = false;
    path = [canary.package] ++ canary.extraPackages;
    environment =
      cfg.runnerHold.gateEnvironment
      // {
        HOME = instance.state;
        DOCKER_HOST = "unix://${socketPath}";
        RUNNER_UNIT = instance.unit;
      };
    serviceConfig = {
      User = "forgejo-podman-runner";
      Group = "forgejo-podman";
      WorkingDirectory = instance.state;
      RuntimeDirectory = instance.serviceName;
      RuntimeDirectoryMode = "0750";
      # Retry transient runner process failures only. ExecCondition still
      # gates each start on the runner hold's reasons.
      Restart = "on-failure";
      RestartSec = "30s";
      TimeoutStartSec = "90s";
      # The runner's shutdown timeout, then its job cancellation and cleanup.
      TimeoutStopSec = "${toString (cfg.shutdownTimeoutSeconds + 300)}s";
      KillMode = "mixed";
      NoNewPrivileges = true;
      ExecCondition = "+${lib.getExe cfg.runnerHold.gate}";
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
        ${lib.escapeShellArg (lib.concatStringsSep "," instance.labels)}${scopeArgument instance} \
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
      sorted by name. The runner hold and the Podman store reset take this
      list.
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
    registrationScope = lib.mkOption {
      type = lib.types.enum ["owner" "instance"];
      default = "owner";
      description = ''
        Scope the registration token grants: `owner` for a user's,
        organisation's or repository's token, which serves only that owner's
        repositories, or `instance` for a site administrator's token, which
        serves every repository. Changing it re-registers the runner once;
        `owner` keeps registrations made before this option existed.
      '';
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
          registrationScope = lib.mkOption {
            type = lib.types.enum ["owner" "instance"];
            default = canary.registrationScope;
            defaultText = lib.literalExpression "config.services.forgejo-actions-runner.podmanCanary.registrationScope";
            description = "Scope this runner's registration token grants; the canary's by default.";
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
        same Podman API. Every runner shares the one runner hold and build
        slice, so the slice's budget is split across all of their jobs.
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
          assertion = cfg.isolatedDocker.enable && cfg.resourcePolicy.enable;
          message = "Podman CI canary requires isolated Docker and the aggregate resource policy.";
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
        {
          # Version 1 tables cannot be mixed with the [[registry]] mirror entry.
          assertion = cfg.registryMirror == null || !(registrySettings ? registries);
          message = "services.forgejo-actions-runner.registryMirror requires virtualisation.containers.registries.settings in the version 2 format.";
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

      # This socket is pulled in by the API service. Stopping that service
      # also closes the listener, so a late client cannot reactivate it.
      systemd.sockets.forgejo-runner-podman = {
        requires = [policyUnit];
        bindsTo = [apiUnit];
        after = [policyUnit];
        partOf = [apiUnit];
        unitConfig = {
          # The resource policy must start before the listener. The default
          # socket sockets.target dependency would reverse that order through
          # basic.target and create a boot transaction cycle.
          DefaultDependencies = false;
          Before = ["shutdown.target"];
          Conflicts = ["shutdown.target"];
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
        ];
        after = [
          "network-online.target"
          socketUnit
          policyUnit
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
          CONTAINERS_CONF_OVERRIDE = lib.mkIf (canary.dnsServers != []) "${containersConf}";
          CONTAINERS_REGISTRIES_CONF = lib.mkIf (cfg.registryMirror != null) "${registriesConf}";
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
          # containers/image takes the first existing per-host directory of
          # ~/.config/containers/certs.d, /etc/containers/certs.d and
          # /etc/docker/certs.d and adds its *.crt to the system roots for
          # that host only. The builder's own directory keeps the CA to this
          # service, and rewriting it at each start drops an unset one.
          ExecStartPre = "${mirrorCaSetup "forgejo-podman-mirror-ca" "${builderState}/.config/containers/certs.d"}";
          ExecStart = "${pkgs.podman}/bin/podman --remote=false --cgroup-manager=cgroupfs --storage-driver=overlay --root=${canary.storageRoot} --runroot=${builderRuntime}/storage system service --time=0";
        };
      };
    })
    (lib.mkIf enabled {
      systemd.services = lib.listToAttrs (
        map (instance: lib.nameValuePair instance.serviceName (runnerService instance)) instances
      );
    })
  ];
}
