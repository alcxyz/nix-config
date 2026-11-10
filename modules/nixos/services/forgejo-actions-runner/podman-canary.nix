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
  scratch = canary.scratch;
  scratchPrepare = pkgs.writeShellApplication {
    name = "forgejo-podman-scratch-prepare";
    runtimeInputs = with pkgs; [coreutils findutils util-linux];
    text = builtins.readFile ./podman-scratch-prepare.sh;
  };
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

  # The Podman runner unit uses the dedicated Podman API, runner hold and
  # build slice, and runs as its own runner account with its own
  # registration, state and runtime directories.
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
      runner = {
        file = ".runner";
        inherit capacity labels;
        env_file = envFile;
        timeout = "${toString cfg.jobTimeoutSeconds}s";
        shutdown_timeout = "${toString cfg.shutdownTimeoutSeconds}s";
        insecure = false;
        fetch_timeout = "5s";
        fetch_interval = "2s";
      };
      container = {
        network = "";
        privileged = false;
        options = lib.concatStringsSep " " (map (name: "-e ${name}") (lib.attrNames canary.jobEnv));
        workdir_parent = null;
        # The API socket, and with the Nix cache its read-only store and job
        # directory (ADR-0109).
        valid_volumes = [socketPath] ++ canary.nixCache.jobVolumes;
        docker_host = "unix://${socketPath}";
        force_pull = false;
      };
      host.workdir_parent = "${state}/host-work";
    };
  };
  canaryInstance = mkInstance {
    serviceName = "forgejo-podman-runner";
    description = "Forgejo Podman pool runner (${canary.name})";
    inherit (canary) labels capacity name registrationTokenFile registrationScope;
  };
  # A second pool slot on the same API and scratch, with its own
  # registration, so a label left out of it, such as forgejo-podman-large,
  # never runs two jobs at once.
  secondSlot = canary.secondSlot;
  secondInstance = mkInstance {
    serviceName = "forgejo-podman-runner-2";
    description = "Forgejo Podman pool runner (${secondSlot.name})";
    inherit (secondSlot) labels name;
    inherit (canary) registrationTokenFile registrationScope;
    capacity = 1;
  };
  instances = [canaryInstance] ++ lib.optional secondSlot.enable secondInstance;
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
      runner first, then the Podman pool runner and, with a second slot,
      forgejo-podman-runner-2. The runner hold and the Podman store reset
      take this list.
    '';
  };

  options.services.forgejo-actions-runner.runnerLabelNames = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf lib.types.str);
    readOnly = true;
    internal = true;
    default =
      {"forgejo-actions-runner.service" = labelNames cfg.labels;}
      // lib.optionalAttrs canary.enable (lib.listToAttrs (map (instance: lib.nameValuePair instance.unit (labelNames instance.labels)) instances));
    description = "Label names of each runner unit, which nixfleet-runner-status reports.";
  };

  options.services.forgejo-actions-runner.podmanCanary = {
    enable = lib.mkEnableOption "separate, qualified rootless Podman CI canary";
    runnerConfig = lib.mkOption {
      type = lib.types.package;
      default = canaryInstance.config;
      readOnly = true;
      internal = true;
      description = "Generated configuration of the Podman pool runner, for contract checks.";
    };
    socketPath = lib.mkOption {
      type = lib.types.str;
      default = socketPath;
      readOnly = true;
      internal = true;
      description = "Socket of the Podman API the Podman runners share.";
    };
    storageRoot = lib.mkOption {
      type = lib.types.str;
      default = "${builderState}/storage";
      readOnly = true;
      internal = true;
      description = ''
        Podman store on disk. With scratch it holds only the image store
        (image layers and image metadata); otherwise also the containers and
        volumes.
      '';
    };
    scratch = {
      enable = lib.mkEnableOption ''
        a RAM-backed Podman graphroot for job throwaway data: container
        writable layers, overlay copy-ups and volumes
        (job workspaces, service data, Buildx state) live in a tmpfs, while
        image layers stay in the image store on disk (#1027)
      '';
      size = lib.mkOption {
        type = lib.types.strMatching "[1-9][0-9]*[MG]";
        default = "8G";
        example = "16G";
        description = ''
          Size limit of the scratch tmpfs, shared by all jobs on this host.
          A job that writes past it fails with "No space left on device"
          instead of pushing the host into memory pressure. tmpfs pages are
          charged to forgejobuilds.slice and mounted noswap, so the slice's
          memoryHigh must leave room for this size plus the jobs' own memory,
          or the slice is throttled and, at memoryMax, OOM-killed.
        '';
      };
      path = lib.mkOption {
        type = lib.types.str;
        default = "/run/forgejo-podman-scratch";
        readOnly = true;
        internal = true;
        description = "Mount point of the scratch tmpfs.";
      };
    };
    graphRoot = lib.mkOption {
      type = lib.types.str;
      default =
        if scratch.enable
        then "${scratch.path}/storage"
        else canary.storageRoot;
      defaultText = lib.literalExpression ''"''${scratch.path}/storage" when scratch is enabled, else storageRoot'';
      readOnly = true;
      internal = true;
      description = ''
        Podman graphroot: container layers and volumes, and without scratch
        also the libpod database (with scratch, the transient store keeps
        that in the runroot).
      '';
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = cfg.package;
      description = "Runner package for the canary, independently qualified from the Docker runner.";
    };
    name = lib.mkOption {
      type = lib.types.str;
      default = "${config.networking.hostName}-podman";
      description = "Forgejo registration name for the Podman pool runner, host-engine (ADR-0041).";
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
    secondSlot = {
      enable = lib.mkEnableOption ''
        a second Podman pool runner, `forgejo-podman-runner-2`, with its own
        registration and one slot, on the same API, store and scratch as the
        first. Unlike a higher `capacity`, it can serve fewer labels, so jobs
        of a label it leaves out never run two at a time. Both slots' jobs
        share the scratch tmpfs: size it, and the memory limits, for both
      '';
      labels = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = canary.labels;
        defaultText = lib.literalExpression "config.services.forgejo-actions-runner.podmanCanary.labels";
        description = "Labels of the second slot, a subset of the first slot's.";
      };
      name = lib.mkOption {
        type = lib.types.str;
        default = "${canary.name}-2";
        defaultText = lib.literalExpression ''"''${config.services.forgejo-actions-runner.podmanCanary.name}-2"'';
        description = "Forgejo registration name of the second slot.";
      };
      runnerConfig = lib.mkOption {
        type = lib.types.package;
        default = secondInstance.config;
        readOnly = true;
        internal = true;
        description = "Generated configuration of the second pool runner, for contract checks.";
      };
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
  };

  config = lib.mkMerge [
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
          # Docker and Podman runners run jobs on different engines; a job
          # must never land on either one by the same label.
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
          assertion =
            !secondSlot.enable
            || (secondSlot.labels
              != []
              && lib.all (label: lib.elem label canary.labels) secondSlot.labels
              && uniqueLabelNames secondSlot.labels);
          message = "The second Podman pool slot must serve a non-empty subset of the first slot's labels.";
        }
        {
          assertion = !secondSlot.enable || !(lib.elem secondSlot.name [canary.name cfg.name]);
          message = "The second Podman pool slot needs its own registration name.";
        }
        {
          assertion = lib.hasPrefix "/" canary.registrationTokenFile;
          message = "Podman CI canary requires an absolute registrationTokenFile path.";
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
          ExecStartPre = let
            mirrorCa = "${mirrorCaSetup "forgejo-podman-mirror-ca" "${builderState}/.config/containers/certs.d"}";
          in
            if scratch.enable
            then [
              mirrorCa
              # As root: refuse to start unless the scratch tmpfs is mounted,
              # empty the graphroot (its metadata went with the runroot), and
              # move a store left from before scratch, which holds
              # containers, aside as reset trash.
              "+${lib.getExe scratchPrepare} ${lib.escapeShellArgs [scratch.path canary.graphRoot canary.storageRoot]}"
            ]
            else mirrorCa;
          ExecStart = lib.concatStringsSep " " ([
              "${pkgs.podman}/bin/podman --remote=false --cgroup-manager=cgroupfs --storage-driver=overlay"
              "--root=${canary.graphRoot}"
            ]
            # The transient store keeps the libpod database and container
            # metadata in the runroot, out of the size-limited scratch, so a
            # job that fills the scratch cannot fail the API's own writes.
            ++ lib.optionals scratch.enable ["--imagestore=${canary.storageRoot}" "--transient-store"]
            ++ ["--runroot=${builderRuntime}/storage system service --time=0"]);
        };
        # The API starts after the tmpfs, and its root ExecStartPre refuses
        # to start without it, so scratch never lands under the mount point.
        # Only Wants: adding or removing the mount in a deploy must not stop
        # a running API and cancel its job (restartIfChanged = false).
        unitConfig = lib.mkIf scratch.enable {
          WantsMountsFor = [scratch.path];
        };
      };

      systemd.mounts = lib.optional scratch.enable {
        description = "RAM scratch for the Podman CI store (#1027)";
        what = "tmpfs";
        where = scratch.path;
        type = "tmpfs";
        # No nosuid or nodev: container layers hold setuid binaries, and
        # overlay whiteouts are device nodes. noswap keeps scratch off the
        # swap disks under host memory pressure: the CI slice is throttled
        # or, at its memoryMax, OOM-killed instead.
        options = "size=${scratch.size},mode=0755,noswap";
        unitConfig = {
          DefaultDependencies = false;
          # A deploy that turns scratch off leaves the tmpfs mounted and the
          # running API on it, until `runners restart` moves the API to the
          # disk store; unmount it then, or let the next reboot drop it.
          X-StopOnRemoval = false;
        };
        before = ["local-fs.target" "umount.target"];
        conflicts = ["umount.target"];
        wantedBy = ["local-fs.target"];
      };
    })
    (lib.mkIf enabled {
      systemd.services = lib.listToAttrs (
        map (instance: lib.nameValuePair instance.serviceName (runnerService instance)) instances
      );
    })
  ];
}
