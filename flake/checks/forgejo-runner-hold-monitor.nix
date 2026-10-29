{
  lib,
  pkgs,
  self,
}:
if !pkgs.stdenv.hostPlatform.isLinux
then pkgs.runCommand "forgejo-runner-hold-monitor-linux-only" {} ''touch "$out";''
else let
  # A standalone runner without a storage monitor: enabling the hold monitor
  # must then demand an explicit ping base.
  standalone = storageMonitor:
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
            networking.hostName = "fixture";
            services.storage-health-monitor = lib.mkIf storageMonitor {
              enable = true;
              pingBaseFile = "/run/fixture/ping-base";
            };
            services.forgejo-actions-runner = {
              enable = true;
              labels = ["test:docker://example.invalid/test:latest"];
              secretsFile = pkgs.writeText "dummy-runner-secrets.yaml" "dummy: encrypted-fixture";
              isolatedDocker.enable = true;
              holdMonitor.enable = true;
            };
          };
        })
      ];
    }).config;
  inherited = standalone true;
  missing = standalone false;
  failedAssertions = config: map (assertion: assertion.message) (builtins.filter (assertion: !assertion.assertion) config.assertions);
  service = inherited.systemd.services.forgejo-runner-hold-monitor;
  timer = inherited.systemd.timers.forgejo-runner-hold-monitor;
  hosts = lib.genAttrs ["nex" "nux" "xev" "xyz"] (name: self.nixosConfigurations.${name}.config);
  hostService = name: hosts.${name}.systemd.services.forgejo-runner-hold-monitor;
  tests = ./test-forgejo-runner-hold-monitor.py;
in
  # The bare fixtures fail unrelated boot assertions; only this one matters.
  assert !lib.any (lib.hasInfix "holdMonitor needs pingBaseFile") (failedAssertions inherited);
  assert lib.any (lib.hasInfix "holdMonitor needs pingBaseFile") (failedAssertions missing);
  assert service.environment.PING_BASE_FILE == "/run/fixture/ping-base";
  assert service.environment.SLUG == "ci-runners-fixture";
  assert service.environment.MAX_HOLD_SECONDS == "1800";
  assert service.environment.RUNNER_UNITS == "forgejo-actions-runner.service";
  assert service.environment.STANDBY_UNITS == "";
  assert service.serviceConfig.Type == "oneshot";
  assert service.serviceConfig.RuntimeDirectoryPreserve == "yes";
  assert service.serviceConfig.ReadOnlyPaths == ["-/run/forgejo-runner-aggregate-pressure"];
  assert !(service.serviceConfig ? User);
  assert timer.timerConfig.OnUnitActiveSec == "5m";
  # Every runner host reports holds through its storage monitor's ping base.
  assert lib.all (name: hosts.${name}.services.forgejo-actions-runner.holdMonitor.enable) (lib.attrNames hosts);
  assert lib.all (name: (hostService name).environment.PING_BASE_FILE == hosts.${name}.services.storage-health-monitor.pingBaseFile) (lib.attrNames hosts);
  assert lib.all (name: (hostService name).environment.SLUG == "ci-runners-${name}") (lib.attrNames hosts);
  # xev's ci-fast runner is a standby (ADR-0097); no other host has one.
  assert (hostService "xev").environment.STANDBY_UNITS == "forgejo-podman-runner-fast.service";
  assert lib.all (name: (hostService name).environment.STANDBY_UNITS == "") ["nex" "nux" "xyz"];
  assert (hostService "xyz").environment.GAME_ADMISSION_ENABLED == "1";
    pkgs.runCommand "forgejo-runner-hold-monitor-contract" {
      nativeBuildInputs = [pkgs.python3];
    } ''
      python3 -I ${tests} ${service.serviceConfig.ExecStart}
      touch "$out"
    ''
