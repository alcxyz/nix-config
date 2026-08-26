{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.services.forgejo-actions-runner;

  settingsFormat = pkgs.formats.yaml { };
  stateDir = "/var/lib/forgejo/runner";
  runtimeDir = "/run/forgejo-runner";
  envFile = "${runtimeDir}/${cfg.name}.env";
  labelsFile = "${stateDir}/.labels";
  nameFile = "${stateDir}/.runner-name";

  secretName = key: "forgejo_runner_${key}";
  secretPath = key: "/run/secrets/${secretName key}";

  secretKeys = lib.unique ([ "runner_token" ] ++ lib.attrValues cfg.secretEnv);

  allEnvNames = lib.unique ((lib.attrNames cfg.jobEnv) ++ (lib.attrNames cfg.secretEnv));
  containerRuntimeOptions = lib.concatStringsSep " " (
    (map (name: "-e ${name}") allEnvNames) ++ cfg.containerOptions
  );

  runnerConfig = settingsFormat.generate "forgejo-runner-config.yaml" {
    log.level = cfg.logLevel;
    runner = {
      file = ".runner";
      capacity = cfg.capacity;
      env_file = envFile;
      timeout = "3600s";
      insecure = false;
      fetch_timeout = "5s";
      fetch_interval = "2s";
    };
    container = {
      network = "";
      privileged = false;
      options = containerRuntimeOptions;
      workdir_parent = null;
      valid_volumes = [ "/var/run/docker.sock" ];
      docker_host = cfg.dockerHost;
      force_pull = false;
    };
    host.workdir_parent = "${stateDir}/host-work";
  };

  literalEnvScript = lib.concatLines (
    lib.mapAttrsToList (name: value: ''
      printf '%s=%s\n' ${lib.escapeShellArg name} ${lib.escapeShellArg value} >> "$env_tmp"
    '') cfg.jobEnv
  );

  secretEnvScript = lib.concatLines (
    lib.mapAttrsToList (name: key: ''
      printf '%s=' ${lib.escapeShellArg name} >> "$env_tmp"
      ${pkgs.coreutils}/bin/tr -d '\n' < ${lib.escapeShellArg (secretPath key)} >> "$env_tmp"
      printf '\n' >> "$env_tmp"
    '') cfg.secretEnv
  );

  secretChecksScript = lib.concatLines (
    map (key: ''
      test -s ${lib.escapeShellArg (secretPath key)}
    '') secretKeys
  );

  labelsWanted = lib.concatStringsSep "," cfg.labels;

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
in
{
  options.services.forgejo-actions-runner = {
    enable = lib.mkEnableOption "native Forgejo Actions runner";

    package = lib.mkPackageOption pkgs "forgejo-runner" { };

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
      default = [ ];
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
      default = "unix:///var/run/docker.sock";
    };

    containerOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--cpu-shares=512" ];
      description = ''
        Additional Docker run options applied to every job container. Prefer
        scheduling weights over hard CPU quotas when the runner should use
        otherwise-idle capacity but yield under contention.
      '';
    };

    secretsFile = lib.mkOption {
      type = lib.types.path;
      default = inputs.nix-secrets.secrets.files.integrations.forgejoRunner;
      description = "SOPS file containing Forgejo runner registration and job environment secrets.";
    };

    jobEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Literal environment values written to the runner job env file.";
    };

    secretEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
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
      enable = lib.mkEnableOption "disk-pressure-aware Docker build-cache pruning" // {
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
    assertions = [
      {
        assertion = cfg.labels != [ ];
        message = "services.forgejo-actions-runner.labels must not be empty.";
      }
      {
        assertion = config.virtualisation.docker.enable;
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
    ];

    users.groups.forgejo-runner = { };
    users.users.forgejo-runner = {
      isSystemUser = true;
      group = "forgejo-runner";
      extraGroups = [ "docker" ];
    };

    # Runner jobs leave build cache and pulled images in the host Docker
    # daemon. Keep one week for repeat builds, then reclaim only unused data.
    # Volumes are deliberately excluded from this generic policy.
    virtualisation.docker.autoPrune = {
      enable = lib.mkDefault true;
      dates = lib.mkDefault "weekly";
      randomizedDelaySec = lib.mkDefault "6h";
      flags = lib.mkDefault [
        "--all"
        "--filter=until=168h"
      ];
    };

    systemd.services.forgejo-runner-cache-pressure-prune = lib.mkIf cfg.cachePressure.enable {
      description = "Prune Forgejo runner build cache under disk pressure";
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe cachePressurePrune;
      };
    };

    systemd.timers.forgejo-runner-cache-pressure-prune = lib.mkIf cfg.cachePressure.enable {
      description = "Check Forgejo runner build-cache disk pressure";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = cfg.cachePressure.interval;
        RandomizedDelaySec = "2m";
        Persistent = true;
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
          restartUnits = [ "forgejo-actions-runner.service" ];
        };
      }) secretKeys
    );

    systemd.tmpfiles.rules = [
      "d /var/lib/forgejo 0750 forgejo-runner forgejo-runner -"
      "d ${stateDir} 0750 forgejo-runner forgejo-runner -"
      "Z ${stateDir} 0750 forgejo-runner forgejo-runner -"
    ];

    systemd.services.forgejo-actions-runner = {
      description = "Forgejo Actions Runner (${cfg.name})";
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "docker.service"
      ];
      requires = [
        "docker.service"
      ];
      wantedBy = [ "multi-user.target" ];
      path = [ cfg.package ] ++ cfg.extraPackages;
      environment = {
        HOME = stateDir;
        DOCKER_HOST = cfg.dockerHost;
      };
      serviceConfig = {
        User = "forgejo-runner";
        Group = "forgejo-runner";
        SupplementaryGroups = [ "docker" ];
        WorkingDirectory = stateDir;
        RuntimeDirectory = "forgejo-runner";
        RuntimeDirectoryMode = "0750";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStartSec = "90s";
        NoNewPrivileges = true;
      };
      preStart = ''
        set -euo pipefail

        test -S /var/run/docker.sock
        docker version --format '{{.Server.Version}}' >/dev/null
        ${secretChecksScript}

        install -d -m 0750 ${lib.escapeShellArg stateDir}
        env_tmp="$(mktemp ${lib.escapeShellArg runtimeDir}/env.XXXXXX)"
        chmod 0600 "$env_tmp"
        ${literalEnvScript}
        ${secretEnvScript}
        mv "$env_tmp" ${lib.escapeShellArg envFile}

        labels_wanted=${lib.escapeShellArg labelsWanted}
        labels_current="$(cat ${lib.escapeShellArg labelsFile} 2>/dev/null || true)"
        name_current="$(cat ${lib.escapeShellArg nameFile} 2>/dev/null || true)"

        if [ ! -f .runner ] || [ "$labels_current" != "$labels_wanted" ] || [ "$name_current" != ${lib.escapeShellArg cfg.name} ]; then
          rm -f .runner
          token="$(tr -d '\n' < ${lib.escapeShellArg (secretPath "runner_token")})"
          forgejo-runner register \
            --instance ${lib.escapeShellArg cfg.url} \
            --token "$token" \
            --name ${lib.escapeShellArg cfg.name} \
            --labels "$labels_wanted" \
            --no-interactive
          printf '%s\n' "$labels_wanted" > ${lib.escapeShellArg labelsFile}
          printf '%s\n' ${lib.escapeShellArg cfg.name} > ${lib.escapeShellArg nameFile}
        fi
      '';
      script = ''
        exec forgejo-runner daemon --config ${runnerConfig}
      '';
    };
  };
}
