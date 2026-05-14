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
  containerOptions = lib.concatStringsSep " " (map (name: "-e ${name}") allEnvNames);

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
      options = containerOptions;
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

  labelsWanted = lib.concatStringsSep "," cfg.labels;
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
    ];

    users.groups.forgejo-runner = { };
    users.users.forgejo-runner = {
      isSystemUser = true;
      group = "forgejo-runner";
      extraGroups = [ "docker" ];
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
        test -s ${lib.escapeShellArg (secretPath "runner_token")}

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
