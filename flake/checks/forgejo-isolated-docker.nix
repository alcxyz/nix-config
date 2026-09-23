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
    (import "${pkgs.path}/nixos/lib/eval-config.nix" {
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
  guard = services.forgejo-runner-io-pressure-guard.serviceConfig.ExecStart;
  guardSource = ../../modules/nixos/services/forgejo-actions-runner/aggregate-pressure-guard.sh;
  lifecycleStop = services.forgejo-runner-aggregate-lifecycle.serviceConfig.ExecStop;
  lifecycleStopSource = ../../modules/nixos/services/forgejo-actions-runner/aggregate-lifecycle-stop.sh;
  runnerStartGate = lib.removePrefix "+" services.forgejo-actions-runner.serviceConfig.ExecCondition;
  runnerStartGateSource = ../../modules/nixos/services/forgejo-actions-runner/runner-start-gate.sh;
  tests = ./test-forgejo-runner-aggregate-pressure.py;
in
  assert runner.dockerHost == "unix:///run/forgejo-docker/docker.sock";
  assert runner.resourcePolicy.enable && runner.ioPressureGuard.enable;
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
  assert builtins.elem "forgejo-runner-io-pressure-guard.service" services.forgejo-runner-docker.bindsTo;
  assert builtins.elem "forgejo-runner-aggregate-lifecycle.service" services.forgejo-runner-docker.requires;
  assert builtins.elem "forgejo-runner-docker.service" services.forgejo-runner-aggregate-lifecycle.after;
  assert builtins.elem "forgejo-runner-docker.service" services.forgejo-runner-aggregate-lifecycle.bindsTo;
  assert builtins.elem "forgejo-runner-io-pressure-guard.service" services.forgejo-runner-aggregate-lifecycle.bindsTo;
  assert builtins.elem "forgejo-runner-aggregate-lifecycle.service" services.forgejo-actions-runner.requires;
  assert builtins.elem "forgejo-runner-aggregate-lifecycle.service" services.forgejo-runner-cache-prune.requires;
  assert !(builtins.elem "forgejo-runner-aggregate-lifecycle.service" services.forgejo-actions-runner.after);
  assert !(builtins.elem "forgejo-runner-aggregate-lifecycle.service" services.forgejo-runner-cache-prune.after);
  assert lib.hasInfix "aggregate-lifecycle-ready" (toString (lib.head services.forgejo-actions-runner.serviceConfig.ExecStartPre));
  assert lib.hasPrefix "+" services.forgejo-actions-runner.serviceConfig.ExecCondition;
  assert lib.hasInfix "aggregate-lifecycle-ready" (toString (lib.head services.forgejo-runner-cache-prune.serviceConfig.ExecStartPre));
  assert !(services.forgejo-runner-aggregate-lifecycle.serviceConfig ? Slice);
  assert !services.forgejo-runner-docker.restartIfChanged;
  assert !services.forgejo-runner-aggregate-lifecycle.restartIfChanged;
  assert !services.forgejo-runner-io-pressure-guard.restartIfChanged;
  assert !services.forgejo-actions-runner.restartIfChanged;
  assert !services.forgejo-runner-resource-policy.restartIfChanged;
  assert services.forgejo-runner-docker.serviceConfig.Restart == "no";
  assert services.forgejo-runner-io-pressure-guard.serviceConfig.Restart == "no";
  assert builtins.elem "forgejo-runner-io-pressure-guard.service" services.forgejo-runner-docker.after;
  assert builtins.elem "forgejo-runner-resource-policy.service" services.forgejo-runner-io-pressure-guard.requires;
  assert !(builtins.elem "forgejo-runner-docker.service" services.forgejo-runner-io-pressure-guard.requires);
  assert !(builtins.elem "forgejo-runner-docker.service" services.forgejo-runner-io-pressure-guard.after);
  assert services.forgejo-runner-resource-policy.partOf == [];
  assert services.forgejo-runner-docker.serviceConfig.User == "forgejo-builder";
  assert !(services.forgejo-runner-io-pressure-guard.serviceConfig ? Slice);
  assert services.forgejo-runner-io-pressure-guard.environment.ADMISSION_CONTROL_ENABLED == "0";
  assert !(services.forgejo-actions-runner.serviceConfig ? KillMode);
  assert services.forgejo-runner-io-pressure-guard.environment.TRANSITION_TIMEOUT_SECONDS == "120";
  assert services.forgejo-runner-cache-pressure-prune.environment.DOCKER_HOST == runner.dockerHost;
  assert services.forgejo-runner-cache-prune.environment.DOCKER_HOST == runner.dockerHost;
  assert !(builtins.elem "--cgroup-parent=forgejobuilds.slice" runner.containerOptions);
  assert legacy.services.forgejo-actions-runner.dockerHost == "unix:///var/run/docker.sock";
  assert legacy.users.users.forgejo-runner.extraGroups == ["docker"];
  assert !legacy.virtualisation.docker.autoPrune.enable;
  assert legacy.systemd.services.forgejo-runner-cache-prune.environment.DOCKER_HOST == "unix:///var/run/docker.sock";
  assert lib.hasInfix "docker builder prune" legacy.systemd.services.forgejo-runner-cache-prune.serviceConfig.ExecStart;
  assert lib.hasInfix "--filter=until=168h" legacy.systemd.services.forgejo-runner-cache-prune.serviceConfig.ExecStart;
  assert lib.hasInfix "--reserved-space 10GB" legacy.systemd.services.forgejo-runner-cache-prune.serviceConfig.ExecStart;
  assert !(lib.hasInfix "docker system prune" legacy.systemd.services.forgejo-runner-cache-prune.serviceConfig.ExecStart);
    pkgs.runCommand "forgejo-runner-isolated-docker-contract" {
      inherit daemonConfig;
      nativeBuildInputs = [pkgs.bash pkgs.jq pkgs.python3 pkgs.shellcheck];
    } ''
      jq --exit-status \
        '.["storage-driver"] == "overlay2"
          and .["data-root"] == "/var/lib/forgejo-docker/overlay2"
          and .["default-ulimits"].nofile == {"Hard": 65536, "Name": "nofile", "Soft": 65536}' \
        "$daemonConfig" >/dev/null
      shellcheck ${guardSource}
      shellcheck ${lifecycleStopSource}
      shellcheck ${runnerStartGateSource}
      python3 ${tests} ${guard} ${lifecycleStop} ${runnerStartGate}
      touch "$out"
    ''
