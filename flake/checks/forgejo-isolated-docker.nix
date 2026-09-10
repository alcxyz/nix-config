{
  lib,
  pkgs,
}:
if !pkgs.stdenv.isLinux
then pkgs.runCommand "forgejo-runner-isolated-docker-linux-only" {} ''touch "$out";''
else let
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
            };
          };
        })
      ];
    }).config;
  host = evaluate true;
  legacy = evaluate false;
  runner = host.services.forgejo-actions-runner;
  services = host.systemd.services;
  guard = services.forgejo-runner-io-pressure-guard.serviceConfig.ExecStart;
  guardSource = ../../modules/nixos/services/forgejo-actions-runner/aggregate-pressure-guard.sh;
  tests = ./test-forgejo-runner-aggregate-pressure.py;
in
  assert runner.dockerHost == "unix:///run/forgejo-docker/docker.sock";
  assert runner.resourcePolicy.enable && runner.ioPressureGuard.enable;
  assert host.users.users.forgejo-builder.autoSubUidGidRange;
  assert host.users.users.forgejo-runner.extraGroups == [];
  assert services.forgejo-actions-runner.serviceConfig.SupplementaryGroups == [];
  assert builtins.elem "forgejo-runner-docker.service" services.forgejo-actions-runner.requires;
  assert !(builtins.elem "docker.service" services.forgejo-actions-runner.requires);
  assert services.forgejo-runner-docker.serviceConfig.Slice == "forgejobuilds.slice";
  assert services.forgejo-runner-docker.serviceConfig.Delegate;
  assert services.forgejo-runner-docker.serviceConfig.OOMPolicy == "continue";
  assert builtins.elem "forgejo-runner-io-pressure-guard.service" services.forgejo-runner-docker.bindsTo;
  assert builtins.elem "forgejo-runner-io-pressure-guard.service" services.forgejo-runner-docker.after;
  assert builtins.elem "forgejo-runner-resource-policy.service" services.forgejo-runner-io-pressure-guard.requires;
  assert !(builtins.elem "forgejo-runner-docker.service" services.forgejo-runner-io-pressure-guard.requires);
  assert !(builtins.elem "forgejo-runner-docker.service" services.forgejo-runner-io-pressure-guard.after);
  assert services.forgejo-runner-resource-policy.partOf == [];
  assert services.forgejo-runner-docker.serviceConfig.User == "forgejo-builder";
  assert !(services.forgejo-runner-io-pressure-guard.serviceConfig ? Slice);
  assert services.forgejo-runner-cache-pressure-prune.environment.DOCKER_HOST == runner.dockerHost;
  assert services.forgejo-runner-cache-prune.environment.DOCKER_HOST == runner.dockerHost;
  assert !(builtins.elem "--cgroup-parent=forgejobuilds.slice" runner.containerOptions);
  assert legacy.services.forgejo-actions-runner.dockerHost == "unix:///var/run/docker.sock";
  assert legacy.users.users.forgejo-runner.extraGroups == ["docker"];
    pkgs.runCommand "forgejo-runner-isolated-docker-contract" {
      nativeBuildInputs = [pkgs.bash pkgs.python3 pkgs.shellcheck];
    } ''
      shellcheck ${guardSource}
      python3 ${tests} ${guard}
      touch "$out"
    ''
