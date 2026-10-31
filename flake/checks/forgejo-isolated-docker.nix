{
  lib,
  pkgs,
}:
if !pkgs.stdenv.hostPlatform.isLinux
then pkgs.runCommand "forgejo-runner-isolated-docker-linux-only" {} ''touch "$out";''
else let
  dummyOrphanMonitor = pkgs.writeShellApplication {
    name = "forgejo-runner-orphan-check";
    text = "exit 0";
  };
  evaluate = isolated:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      specialArgs.inputs = {};
      modules = [
        ../../modules/nixos/services/forgejo-actions-runner
        ({lib, ...}: {
          options.sops.secrets = lib.mkOption {
            type = lib.types.attrs;
            default = {};
          };
          config = {
            system.stateVersion = "25.11";
            virtualisation.docker.enable = true;
            services.forgejo-actions-runner = {
              enable = true;
              labels = ["test:docker://example.invalid/test:latest"];
              secretsFile = pkgs.writeText "dummy-runner-secrets.yaml" "dummy: encrypted-fixture";
              isolatedDocker.enable = isolated;
              cachePressure.enable = true;
              orphanMonitor = lib.mkIf isolated {
                enable = true;
                package = dummyOrphanMonitor;
                tokenFile = "/run/dummy-orphan-api-token";
                repositories = ["example/fixture"];
              };
            };
          };
        })
      ];
    }).config;
  host = evaluate true;
  legacy = evaluate false;
  runner = host.services.forgejo-actions-runner;
  services = host.systemd.services;
  orphanMonitor = services.forgejo-runner-orphan-check.serviceConfig;
  daemonConfig = lib.last (lib.splitString "=" services.forgejo-runner-docker.serviceConfig.ExecStart);
  hold = services.forgejo-runner-hold;
  holdSource = ../../modules/nixos/services/forgejo-actions-runner/runner-hold.sh;
  runnerStartGateSource = ../../modules/nixos/services/forgejo-actions-runner/runner-start-gate.sh;
  apiStartGateSource = ../../modules/nixos/services/forgejo-actions-runner/podman-api-start-gate.sh;
  diskHelperSource = ../../modules/nixos/services/forgejo-actions-runner/disk-space-admission.sh;
  gameSignalSource = ../../modules/nixos/services/game-signal/game-signal.sh;
  gameScanSource = ../../modules/nixos/services/game-signal/game-scan.sh;
  tests = ./test-forgejo-runner-hold.py;
in
  assert runner.dockerHost == "unix:///run/forgejo-docker/docker.sock";
  assert runner.resourcePolicy.enable;
  assert host.users.users.forgejo-builder.autoSubUidGidRange;
  assert host.users.users.forgejo-runner.extraGroups == [];
  assert services.forgejo-actions-runner.serviceConfig.SupplementaryGroups == [];
  assert orphanMonitor.DynamicUser;
  assert orphanMonitor.User == "forgejo-orphan-monitor";
  assert !(orphanMonitor ? Group);
  assert orphanMonitor.SupplementaryGroups == ["forgejo-runner"];
  assert orphanMonitor.LoadCredential == ["api-token:/run/dummy-orphan-api-token"];
  assert orphanMonitor.ProtectProc == "invisible";
  assert orphanMonitor.ProcSubset == "pid";
  assert orphanMonitor.PrivateMounts;
  assert orphanMonitor.KeyringMode == "private";
  assert builtins.elem "forgejo-runner-docker.service" services.forgejo-actions-runner.requires;
  assert !(builtins.elem "docker.service" services.forgejo-actions-runner.requires);
  assert services.forgejo-runner-docker.serviceConfig.Slice == "forgejobuilds.slice";
  assert services.forgejo-runner-docker.serviceConfig.Delegate;
  assert services.forgejo-runner-docker.serviceConfig.OOMPolicy == "continue";
  assert services.forgejo-runner-docker.serviceConfig.LimitNOFILE == 1048576;
  # The retired pressure guard, freeze and lifecycle teardown are gone; the
  # runner hold replaces them and binds nothing to itself (ADR-0106).
  assert !(services ? forgejo-runner-io-pressure-guard);
  assert !(services ? forgejo-runner-aggregate-lifecycle);
  assert !(services ? forgejo-runner-hold-monitor);
  assert !(host.systemd.slices.forgejobuilds.unitConfig ? DefaultDependencies);
  assert services.forgejo-runner-docker.bindsTo == [];
  assert services.forgejo-actions-runner.bindsTo == [];
  assert services.forgejo-runner-docker.requires == ["forgejo-runner-resource-policy.service"];
  assert builtins.elem "forgejo-runner-hold.service" services.forgejo-actions-runner.wants;
  assert builtins.elem "forgejo-runner-hold.service" services.forgejo-actions-runner.after;
  assert hold.wantedBy == ["multi-user.target"];
  assert hold.serviceConfig.Restart == "always";
  assert hold.environment.RUNNER_UNITS == "forgejo-actions-runner.service";
  assert hold.environment.GAME_ENABLED == "0";
  assert hold.environment.DISK_SPACE_ENABLED == "0";
  assert hold.environment.ALERT_ENABLED == "0";
  assert lib.hasPrefix "+" services.forgejo-actions-runner.serviceConfig.ExecCondition;
  assert lib.hasInfix "forgejo-runner-start-gate" services.forgejo-actions-runner.serviceConfig.ExecCondition;
  assert services.forgejo-actions-runner.environment.RUNNER_UNIT == "forgejo-actions-runner.service";
  assert services.forgejo-actions-runner.environment.STATE_DIR == "/run/forgejo-runner-hold";
  assert !(lib.hasInfix "lifecycle-ready" (toString (services.forgejo-actions-runner.serviceConfig.ExecStartPre or "")));
  assert builtins.elem "forgejo-runner-docker.service" services.forgejo-runner-cache-prune.requires;
  assert lib.hasPrefix "+" services.forgejo-runner-docker.serviceConfig.ExecCondition;
  assert builtins.elem "d /run/forgejo-runner-hold 0700 root root -" host.systemd.tmpfiles.rules;
  assert builtins.elem "d /run/forgejo-runner-hold/runners/forgejo-actions-runner.service 0700 root root -" host.systemd.tmpfiles.rules;
  assert !services.forgejo-runner-docker.restartIfChanged;
  assert !services.forgejo-actions-runner.restartIfChanged;
  assert !services.forgejo-runner-resource-policy.restartIfChanged;
  assert services.forgejo-runner-docker.serviceConfig.Restart == "no";
  assert services.forgejo-runner-resource-policy.partOf == [];
  assert services.forgejo-runner-docker.serviceConfig.User == "forgejo-builder";
  assert services.forgejo-actions-runner.serviceConfig.KillMode == "mixed";
  assert services.forgejo-actions-runner.serviceConfig.TimeoutStopSec == "3900s";
  assert services.forgejo-runner-cache-pressure-prune.environment.DOCKER_HOST == runner.dockerHost;
  assert services.forgejo-runner-cache-prune.environment.DOCKER_HOST == runner.dockerHost;
  assert !(builtins.elem "--cgroup-parent=forgejobuilds.slice" runner.containerOptions);
  assert host.services.nixfleet-boot-check.runnerUnits
  == [
    {
      unit = "forgejo-actions-runner.service";
      holdMarkerDirectory = "/run/forgejo-runner-hold/runners/forgejo-actions-runner.service";
    }
  ];
  assert legacy.services.forgejo-actions-runner.dockerHost == "unix:///var/run/docker.sock";
  assert legacy.users.users.forgejo-runner.extraGroups == ["docker"];
  assert !legacy.virtualisation.docker.autoPrune.enable;
  assert !(legacy.systemd.services ? forgejo-runner-hold);
  assert legacy.services.nixfleet-boot-check.runnerUnits
  == [
    {
      unit = "forgejo-actions-runner.service";
      holdMarkerDirectory = null;
    }
  ];
  assert legacy.systemd.services.forgejo-runner-cache-prune.environment.DOCKER_HOST == "unix:///var/run/docker.sock";
  assert lib.hasInfix "docker builder prune" legacy.systemd.services.forgejo-runner-cache-prune.serviceConfig.ExecStart;
  assert lib.hasInfix "--filter=until=168h" legacy.systemd.services.forgejo-runner-cache-prune.serviceConfig.ExecStart;
  assert lib.hasInfix "--reserved-space 10GB" legacy.systemd.services.forgejo-runner-cache-prune.serviceConfig.ExecStart;
  assert !(lib.hasInfix "docker system prune" legacy.systemd.services.forgejo-runner-cache-prune.serviceConfig.ExecStart);
    pkgs.runCommand "forgejo-runner-isolated-docker-contract" {
      inherit daemonConfig;
      nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.gawk pkgs.jq pkgs.python3 pkgs.shellcheck pkgs.util-linux];
    } ''
      jq --exit-status \
        '.["storage-driver"] == "overlay2"
          and .["data-root"] == "/var/lib/forgejo-docker/overlay2"
          and .["default-ulimits"].nofile == {"Hard": 65536, "Name": "nofile", "Soft": 65536}' \
        "$daemonConfig" >/dev/null
      shellcheck -x ${holdSource} ${runnerStartGateSource} ${apiStartGateSource} ${diskHelperSource}
      shellcheck -x ${gameSignalSource} ${gameScanSource}
      GAME_SCAN_FILE=${gameScanSource} DISK_HELPER_FILE=${diskHelperSource} python3 ${tests} ${holdSource} ${runnerStartGateSource} ${gameSignalSource}
      touch "$out"
    ''
