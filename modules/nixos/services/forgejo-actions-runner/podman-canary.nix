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
    registrationScope,
    standby ? null,
    status ? null,
  }: rec {
    inherit serviceName description labels capacity name registrationTokenFile registrationScope standby status;
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
          shutdown_timeout = "3600s";
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
      standby =
        if extra.standby.enable
        then extra.standby
        else null;
      status =
        if extra.status.enable
        then extra.status
        else null;
    })
  canary.extraRunners;
  instances = [canaryInstance] ++ extraInstances;
  standbyInstances = builtins.filter (instance: instance.standby != null) extraInstances;
  statusInstances = builtins.filter (instance: instance.status != null) extraInstances;
  pollSeconds = 15;
  # Consecutive polls spanning at least the given time: the first poll that
  # sees a change starts the span.
  polls = seconds: (seconds + pollSeconds - 1) / pollSeconds + 1;
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
  standbyController = pkgs.writeShellApplication {
    name = "forgejo-podman-standby-controller";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      systemd
      util-linux
    ];
    text = builtins.readFile ./standby-controller.sh;
  };
  # Answers one HTTP request per connection with the runner unit's systemd
  # state, for the standby controller on another host.
  statusResponder = instance:
    pkgs.writeShellApplication {
      name = "${instance.serviceName}-status";
      runtimeInputs = [pkgs.systemd];
      text = ''
        while IFS= read -r -t 5 line; do
          line=''${line%$'\r'}
          [[ -n $line ]] || break
        done
        state=$(systemctl is-active ${instance.unit} || true)
        [[ -n $state ]] || state=unknown
        printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s\n' \
          "$((''${#state} + 1))" "$state"
      '';
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
        RUNNER_STANDBY =
          if instance.standby != null
          then "1"
          else "0";
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
        ${lib.escapeShellArg (lib.concatStringsSep "," instance.labels)}${scopeArgument instance} \
        < ${lib.escapeShellArg instance.registrationTokenFile}
    '';
    script = ''
      exec forgejo-runner daemon --config ${instance.config}
    '';
  };
  standbyService = instance: {
    description = "Run ${instance.unit} while the primary host's runner is down";
    # Stopping the controller releases the standby, which would end a running
    # fallback for as long as its job runs; a changed controller takes effect
    # at the next boot or an explicit restart.
    restartIfChanged = false;
    wantedBy = ["multi-user.target"];
    wants = ["network-online.target"];
    after = [
      "network-online.target"
      guardUnit
      lifecycleUnit
    ];
    environment = {
      RUNNER_UNIT = instance.unit;
      STATUS_URL = instance.standby.statusUrl;
      STATUS_INTERFACE = lib.optionalString (instance.standby.statusInterface != null) instance.standby.statusInterface;
      POLL_SECONDS = toString pollSeconds;
      START_AFTER_POLLS = toString (polls instance.standby.startAfterSeconds);
      STOP_AFTER_POLLS = toString (polls instance.standby.stopAfterSeconds);
    };
    serviceConfig = {
      ExecStart = lib.getExe standbyController;
      Restart = "always";
      RestartSec = "30s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
    };
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
      sorted by name. The pressure guard, start gates, lifecycle teardown and
      the Podman store reset all take this list.
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
          standby = {
            enable = lib.mkEnableOption ''
              standby mode: the runner runs only while the matching runner on
              another host is down, as that host's status endpoint reports.
              The start gate holds the unit until a controller admits it; the
              unit stays enabled so pressure and disk drains still cover it.
              The controller restarts a stopped, enabled standby while the
              primary is down. Stopping its `-standby` unit releases the
              standby until the next switch or boot starts that unit again;
              masking the runner unit keeps it off for good. A switch does not
              restart a running controller'';
            statusUrl = lib.mkOption {
              type = lib.types.strMatching "http://[^ ]+";
              example = "http://192.0.2.10:9478/";
              description = ''
                Status endpoint of the primary runner (`status` on its host).
                Any answer other than `active`, including none, counts as down.
              '';
            };
            statusInterface = lib.mkOption {
              type = lib.types.nullOr (lib.types.strMatching "[A-Za-z0-9_.-]+");
              default = null;
              example = "wt0";
              description = ''
                Network interface the polls must leave through, such as the
                overlay that authenticates the primary host. Null uses the
                routing table.
              '';
            };
            startAfterSeconds = lib.mkOption {
              type = lib.types.ints.positive;
              default = 60;
              description = "How long the primary runner must have been seen down before this runner starts; rounded up to the 15-second poll.";
            };
            stopAfterSeconds = lib.mkOption {
              type = lib.types.ints.positive;
              default = 300;
              description = ''
                How long the primary runner must have been seen back before
                this runner stops; rounded up to the 15-second poll. The stop
                is graceful: running jobs finish here.
              '';
            };
          };
          status = {
            enable = lib.mkEnableOption ''
              a read-only endpoint that reports this runner unit's systemd
              state (`active`, `inactive` and so on) to standby runners on
              other hosts'';
            port = lib.mkOption {
              type = lib.types.port;
              example = 9478;
              description = "TCP port of the status endpoint.";
            };
            interface = lib.mkOption {
              type = lib.types.str;
              example = "wt0";
              description = "The only network interface whose firewall admits the endpoint.";
            };
            allowedAddresses = lib.mkOption {
              type = lib.types.nonEmptyListOf lib.types.str;
              default = ["100.64.0.0/10"];
              description = "Source address prefixes the endpoint's socket accepts; all others are dropped.";
            };
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
        {
          assertion = let
            names =
              map (instance: instance.serviceName) instances
              ++ map (instance: "${instance.serviceName}-standby") standbyInstances
              ++ map (instance: "${instance.serviceName}-status") statusInstances;
          in
            builtins.length (lib.unique names) == builtins.length names;
          message = "A standby controller's or status endpoint's unit name must not match a Podman runner's.";
        }
        {
          assertion = lib.all (instance: instance.status == null) standbyInstances;
          message = "A standby Podman runner cannot also publish a status endpoint.";
        }
        {
          assertion = let
            ports = map (instance: instance.status.port) statusInstances;
          in
            builtins.length (lib.unique ports) == builtins.length ports;
          message = "Podman runner status endpoints need distinct ports.";
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

      services.nixfleet-boot-check.runnerUnits =
        map (instance: {
          inherit (instance) unit;
          holdMarkerDirectory = "/run/forgejo-runner-aggregate-pressure/runners/${instance.unit}";
        })
        instances;
    })
    (lib.mkIf enabled {
      systemd.services = lib.listToAttrs (
        map (instance: lib.nameValuePair instance.serviceName (runnerService instance)) instances
        ++ map (instance: lib.nameValuePair "${instance.serviceName}-standby" (standbyService instance)) standbyInstances
        ++ map (instance:
          lib.nameValuePair "${instance.serviceName}-status@" {
            description = "Report ${instance.unit} state to a standby host";
            # Collect instances that hit the runtime limit instead of keeping
            # them as failed units.
            unitConfig.CollectMode = "inactive-or-failed";
            serviceConfig = {
              ExecStart = lib.getExe (statusResponder instance);
              StandardInput = "socket";
              StandardOutput = "socket";
              StandardError = "journal";
              RuntimeMaxSec = "15s";
              DynamicUser = true;
              CapabilityBoundingSet = "";
              LockPersonality = true;
              MemoryDenyWriteExecute = true;
              NoNewPrivileges = true;
              PrivateDevices = true;
              PrivateTmp = true;
              ProtectHome = true;
              ProtectSystem = "strict";
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectControlGroups = true;
              # The accepted connection is inherited; systemctl needs only
              # the system bus.
              RestrictAddressFamilies = "AF_UNIX";
              RestrictNamespaces = true;
              SystemCallArchitectures = "native";
            };
          })
        statusInstances
      );

      systemd.sockets = lib.listToAttrs (map (instance:
        lib.nameValuePair "${instance.serviceName}-status" {
          description = "Status endpoint of ${instance.unit}";
          wantedBy = ["sockets.target"];
          listenStreams = [(toString instance.status.port)];
          socketConfig = {
            Accept = true;
            MaxConnections = 8;
            MaxConnectionsPerSource = 2;
            IPAddressAllow = instance.status.allowedAddresses;
            IPAddressDeny = "any";
          };
        })
      statusInstances);

      networking.firewall.interfaces = lib.mkMerge (map (instance: {
          ${instance.status.interface}.allowedTCPPorts = [instance.status.port];
        })
        statusInstances);
    })
  ];
}
