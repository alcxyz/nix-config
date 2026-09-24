{
  lib,
  pkgs,
}:
if !pkgs.stdenv.hostPlatform.isLinux
then pkgs.runCommand "forgejo-podman-canary-linux-only" {} ''touch "$out"''
else let
  primary = "forgejo-actions-runner.service";
  canary = "forgejo-podman-runner.service";
  both = "${primary} ${canary}";
  evaluate = enabled: labels:
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
              name = "fixture-docker";
              labels = ["docker-primary:docker://example.invalid/docker:latest"];
              secretsFile = pkgs.writeText "dummy-runner-secrets.yaml" "dummy: encrypted-fixture";
              secretEnv.FIXTURE_SECRET = "runner_token";
              isolatedDocker.enable = true;
              ioPressureGuard.admissionControl.enable = true;
              podmanCanary = {
                enable = enabled;
                name = "fixture-podman";
                inherit labels;
                registrationTokenFile = "/run/fixture/podman-registration-token";
              };
            };
          };
        })
      ];
    }).config;
  validLabels = ["podman-canary:docker://example.invalid/podman:latest"];
  disabled = evaluate false validLabels;
  enabled = evaluate true validLabels;
  overlap = evaluate true ["docker-primary:docker://example.invalid/different-image:latest"];
  hostLabel = evaluate true ["podman-canary:host"];
  unit = enabled.systemd.services.forgejo-podman-runner;
  api = enabled.systemd.services.forgejo-runner-podman;
  socket = enabled.systemd.sockets.forgejo-runner-podman;
  guard = enabled.systemd.services.forgejo-runner-io-pressure-guard;
  lifecycle = enabled.systemd.services.forgejo-runner-aggregate-lifecycle;
  dockerRunner = enabled.systemd.services.forgejo-actions-runner;
  failedAssertion = config: message:
    lib.any (entry: !entry.assertion && entry.message == message) config.assertions;
  gateSource = ../../modules/nixos/services/forgejo-actions-runner/podman-api-start-gate.sh;
in
  assert !(disabled.systemd.services ? forgejo-podman-runner);
  assert !(disabled.systemd.services ? forgejo-runner-podman);
  assert !(disabled.systemd.sockets ? forgejo-runner-podman);
  assert enabled.users.users.forgejo-podman-runner.group == "forgejo-podman";
  assert enabled.users.users.forgejo-podman-builder.group == "forgejo-podman";
  assert enabled.users.users.forgejo-podman-runner.home != enabled.users.users.forgejo-podman-builder.home;
  assert enabled.users.users.forgejo-podman-runner.home != enabled.users.users.forgejo-runner.home;
  assert api.serviceConfig.User == "forgejo-podman-builder";
  assert unit.serviceConfig.User == "forgejo-podman-runner";
  assert api.serviceConfig.Slice == "forgejobuilds.slice";
  assert enabled.systemd.services.forgejo-runner-docker.serviceConfig.Slice == "forgejobuilds.slice";
  assert socket.socketConfig.ListenStream == "/run/forgejo-podman/podman.sock";
  assert unit.environment.DOCKER_HOST == "unix://${socket.socketConfig.ListenStream}";
  assert unit.environment.DOCKER_HOST != dockerRunner.environment.DOCKER_HOST;
  assert guard.environment.RUNNER_UNITS == both;
  assert lifecycle.environment.RUNNER_UNITS == both;
  assert dockerRunner.environment.RUNNER_UNITS == both;
  assert unit.environment.RUNNER_UNITS == both;
  assert api.environment.RUNNER_UNITS == both;
  assert dockerRunner.environment.RUNNER_UNIT == primary;
  assert unit.environment.RUNNER_UNIT == canary;
  assert lib.hasPrefix "+" dockerRunner.serviceConfig.ExecCondition;
  assert lib.hasPrefix "+" unit.serviceConfig.ExecCondition;
  assert lib.hasPrefix "+" api.serviceConfig.ExecCondition;
  assert !enabled.virtualisation.podman.dockerSocket.enable;
  assert !(unit.environment ? FIXTURE_SECRET);
  assert !(lib.hasInfix "FIXTURE_SECRET" unit.preStart);
  assert failedAssertion overlap "Podman CI canary label names must not overlap Docker runner label names.";
  assert failedAssertion hostLabel "Podman CI canary requires explicit name:docker://image labels.";
    pkgs.runCommand "forgejo-podman-canary-contract" {
      nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.shellcheck pkgs.systemd pkgs.util-linux];
    } ''
      shellcheck ${gateSource}
      fixture="$(mktemp -d)"
      trap 'rm -rf "$fixture"' EXIT
      state="$fixture/state"
      mkdir -p "$state/runners/${canary}"
      printf '%s\n' ${lib.escapeShellArg primary} ${lib.escapeShellArg canary} > "$state/runner-units"
      cat > "$fixture/systemctl" <<'SH'
      #!${pkgs.bash}/bin/bash
      set -euo pipefail
      if [[ $1 == is-active && $2 == --quiet ]]; then
        [[ ''${MOCK_GUARD_ACTIVE:-1} == 1 && $3 == forgejo-runner-io-pressure-guard.service ]]
      elif [[ $1 == show && $2 == --property=FreezerState && $3 == --value && $4 == forgejobuilds.slice ]]; then
        printf '%s\n' "''${MOCK_FREEZER:-running}"
      else
        exit 2
      fi
      SH
      chmod +x "$fixture/systemctl"
      run_gate() {
        STATE_DIR="$state" SYSTEMCTL_BIN="$fixture/systemctl" RUNNER_UNITS=${lib.escapeShellArg both} \
          bash ${gateSource} >/dev/null 2>&1
      }
      run_gate
      rm "$state/runner-units"
      if run_gate; then exit 1; fi
      printf '%s\n' ${lib.escapeShellArg primary} > "$state/runner-units"
      if run_gate; then exit 1; fi
      printf '%s\n' ${lib.escapeShellArg primary} ${lib.escapeShellArg canary} > "$state/runner-units"
      for marker in owned pending teardown-required; do
        touch "$state/$marker"
        if run_gate; then exit 1; fi
        rm "$state/$marker"
      done
      if MOCK_GUARD_ACTIVE=0 run_gate; then exit 1; fi
      if MOCK_FREEZER=frozen run_gate; then exit 1; fi
      run_gate
      touch "$out"
    ''
