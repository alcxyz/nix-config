{
  lib,
  pkgs,
}:
if !pkgs.stdenv.hostPlatform.isLinux
then pkgs.runCommand "forgejo-docker-retention-linux-only" {} ''touch "$out"''
else let
  evaluate = extra:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      specialArgs.inputs = {};
      modules = [
        ../../modules/nixos/services/forgejo-actions-runner
        {config = extra;}
        ({lib, ...}: {
          options.sops.secrets = lib.mkOption {
            type = lib.types.attrs;
            default = {};
          };
          config = {
            system.stateVersion = "25.11";
            virtualisation.docker.enable = true;
            services.forgejo-actions-runner = {
              enable = lib.mkDefault true;
              isolatedDocker.enable = lib.mkDefault true;
              labels = ["test:docker://example.invalid/test:latest"];
              secretsFile = pkgs.writeText "dummy-runner-secrets.yaml" "dummy: encrypted-fixture";
            };
          };
        })
      ];
    }).config;
  retentionConfig.services.forgejo-actions-runner.isolatedDocker.retention.enable = true;
  defaults = evaluate {};
  retained = evaluate retentionConfig;
  custom = evaluate {
    services.forgejo-actions-runner.isolatedDocker.retention = {
      enable = true;
      budget = "10GiB";
      unusedAge = "24h";
    };
  };
  legacy = evaluate (lib.recursiveUpdate retentionConfig {
    services.forgejo-actions-runner.isolatedDocker.enable = false;
  });
  disabled = evaluate (lib.recursiveUpdate retentionConfig {
    services.forgejo-actions-runner.enable = false;
  });
  daemonFile = c: lib.last (lib.splitString "=" c.systemd.services.forgejo-runner-docker.serviceConfig.ExecStart);
  prune = c: c.systemd.services.forgejo-runner-cache-prune;
  timer = c: c.systemd.timers.forgejo-runner-cache-prune.timerConfig;
  validOption = field: value:
    builtins.tryEval
    (evaluate {
      services.forgejo-actions-runner.isolatedDocker.retention.${field} = value;
    }).services.forgejo-actions-runner.isolatedDocker.retention.${
      field
    };
in
  assert !defaults.services.forgejo-actions-runner.isolatedDocker.retention.enable;
  assert defaults.services.forgejo-actions-runner.isolatedDocker.retention.budget == "20GiB";
  assert defaults.services.forgejo-actions-runner.isolatedDocker.retention.unusedAge == "48h";
  assert (timer defaults).OnCalendar == "weekly";
  assert lib.hasSuffix "system prune --force --all --filter=until=168h" (prune defaults).serviceConfig.ExecStart;
  assert (timer retained).OnCalendar == "daily";
  assert (timer retained).Persistent;
  assert lib.hasSuffix "system prune --force --all --filter=until=48h" (prune retained).serviceConfig.ExecStart;
  assert lib.hasSuffix "system prune --force --all --filter=until=24h" (prune custom).serviceConfig.ExecStart;
  assert lib.all (c: let
    services = c.systemd.services;
  in
    (prune c).environment.DOCKER_HOST
    == "unix:///run/forgejo-docker/docker.sock"
    && !(lib.hasInfix "--volumes" (prune c).serviceConfig.ExecStart)
    && lib.elem "forgejo-runner-docker.service" (prune c).requires
    && lib.elem "forgejo-runner-docker.service" (prune c).after
    && !services.forgejo-runner-docker.restartIfChanged
    && services.host-docker-cache-prune.serviceConfig == defaults.systemd.services.host-docker-cache-prune.serviceConfig
    && services.host-docker-cache-prune.requires == defaults.systemd.services.host-docker-cache-prune.requires
    && services.host-docker-cache-prune.environment == defaults.systemd.services.host-docker-cache-prune.environment
    && c.systemd.timers.host-docker-cache-prune.timerConfig == defaults.systemd.timers.host-docker-cache-prune.timerConfig
    && c.systemd.timers.host-docker-cache-prune.wantedBy == defaults.systemd.timers.host-docker-cache-prune.wantedBy
    && c.virtualisation.docker.daemon.settings == defaults.virtualisation.docker.daemon.settings) [retained custom];
  assert (timer legacy).OnCalendar == "weekly";
  assert lib.hasInfix "docker builder prune" (prune legacy).serviceConfig.ExecStart;
  assert !(legacy.systemd.services ? forgejo-runner-docker);
  assert !(disabled.systemd.services ? forgejo-runner-cache-prune);
  assert !(validOption "budget" "0GiB").success;
  assert !(validOption "budget" "20GiB --volumes").success;
  assert !(validOption "unusedAge" "0h").success;
  assert !(validOption "unusedAge" "48h --volumes").success;
    pkgs.runCommand "forgejo-docker-retention-contract" {
      defaultConfig = daemonFile defaults;
      retainedConfig = daemonFile retained;
      customConfig = daemonFile custom;
      nativeBuildInputs = [pkgs.docker pkgs.jq];
    } ''
      jq -e 'has("builder") | not' "$defaultConfig" >/dev/null
      check_policy() {
        jq -e --arg budget "$2" --arg age "$3" '
          .builder.gc == {
            enabled: true,
            policy: [
              {reservedSpace: $budget, maxUsedSpace: $budget, filter: [("until=" + $age)]},
              {reservedSpace: $budget, maxUsedSpace: $budget, all: true}
            ]
          }' "$1" >/dev/null
        # --validate parses configuration and exits without starting a daemon.
        dockerd --validate --config-file="$1"
      }
      check_policy "$retainedConfig" 20GiB 48h
      check_policy "$customConfig" 10GiB 24h
      dockerd --validate --config-file="$defaultConfig"
      touch "$out"
    ''
