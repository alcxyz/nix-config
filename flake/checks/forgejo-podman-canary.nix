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
  extra = "forgejo-podman-runner-fast.service";
  three-units = "${both} ${extra}";
  evaluate = enabled: labels: extra:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      specialArgs.inputs = {};
      modules = [
        {config = extra;}
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
  disabled = evaluate false validLabels {};
  enabled = evaluate true validLabels {};
  overlap = evaluate true ["docker-primary:docker://example.invalid/different-image:latest"] {};
  hostLabel = evaluate true ["podman-canary:host"] {};
  cleanupConfig = {
    services.forgejo-actions-runner = {
      idlePodmanCleanup.enable = true;
      ioPressureGuard.diskSpace.enable = true;
    };
  };
  cleanupOnly = evaluate true validLabels cleanupConfig;
  monitoredCleanup = evaluate true validLabels (lib.recursiveUpdate cleanupConfig {
    services.storage-health-monitor = {
      enable = true;
      pingBaseFile = "/run/fixture-unused-ping";
    };
  });
  hourlyCleanup = evaluate true validLabels (lib.recursiveUpdate cleanupConfig {
    services.forgejo-actions-runner.idlePodmanCleanup = {
      interval = "1h";
      healthMaximumAgeSeconds = 7200;
    };
    services.storage-health-monitor = {
      enable = true;
      pingBaseFile = "/run/fixture-unused-ping";
    };
  });
  monitorOnly = evaluate true validLabels {
    services.storage-health-monitor = {
      enable = true;
      pingBaseFile = "/run/fixture-unused-ping";
    };
  };
  cleanupUnits = config: builtins.filter (unit: unit.name == "forgejo-idle-podman-cleanup.service") config.services.storage-health-monitor.units;
  unit = enabled.systemd.services.forgejo-podman-runner;
  api = enabled.systemd.services.forgejo-runner-podman;
  socket = enabled.systemd.sockets.forgejo-runner-podman;
  guard = enabled.systemd.services.forgejo-runner-io-pressure-guard;
  lifecycle = enabled.systemd.services.forgejo-runner-aggregate-lifecycle;
  dockerRunner = enabled.systemd.services.forgejo-actions-runner;
  failedAssertion = config: message:
    lib.any (entry: !entry.assertion && entry.message == message) config.assertions;
  failedAssertions = config: map (entry: entry.message) (builtins.filter (entry: !entry.assertion) config.assertions);
  gateSource = ../../modules/nixos/services/forgejo-actions-runner/podman-api-start-gate.sh;

  # An extra Podman runner beside the canary, with ci-fast as a shared
  # overflow label on both (ADR-0097).
  fastLabel = "ci-fast:docker://example.invalid/fast:latest";
  withExtra = canaryLabels: extraRunner: overrides:
    evaluate true canaryLabels (lib.recursiveUpdate {
        networking.hostName = "fixture";
        services.forgejo-actions-runner.podmanCanary.extraRunners.fast = extraRunner;
      }
      overrides);
  sharedConfig = {services.forgejo-actions-runner.podmanCanary.sharedLabels = ["ci-fast"];};
  three = withExtra (validLabels ++ [fastLabel]) {labels = [fastLabel];} sharedConfig;
  threeCleanup = withExtra validLabels {labels = [fastLabel];} cleanupConfig;
  extraUnit = three.systemd.services.forgejo-podman-runner-fast;
  threeUnit = three.systemd.services.forgejo-podman-runner;
  extraConfigFile = lib.last (lib.splitString " " (lib.removeSuffix "\n" extraUnit.script));
  canaryConfigFile = lib.last (lib.splitString " " (lib.removeSuffix "\n" threeUnit.script));
  sharedWithoutAllowance = withExtra (validLabels ++ [fastLabel]) {labels = [fastLabel];} {};
  sharedDifferentImage = withExtra (validLabels ++ [fastLabel]) {labels = ["ci-fast:docker://example.invalid/other:latest"];} sharedConfig;
  sharedWithDocker = withExtra validLabels {labels = ["docker-primary:docker://example.invalid/docker:latest"];} {
    services.forgejo-actions-runner.podmanCanary.sharedLabels = ["docker-primary"];
  };
  allowanceNamesDocker = withExtra validLabels {labels = [fastLabel];} {
    services.forgejo-actions-runner.podmanCanary.sharedLabels = ["docker-primary"];
  };
  extraHostLabel = withExtra validLabels {labels = ["ci-fast:host"];} {};
  extraBadName = evaluate true validLabels {
    services.forgejo-actions-runner.podmanCanary.extraRunners.Fast.labels = [fastLabel];
  };
  extraDuplicateName = withExtra validLabels {
    labels = [fastLabel];
    name = "fixture-podman";
  } {};
  extraWithoutCanary = evaluate false validLabels {
    services.forgejo-actions-runner.podmanCanary.extraRunners.fast.labels = [fastLabel];
  };
  recoveryText = config: (lib.findFirst (package: (package.name or "") == "forgejo-runner-cleanup-fence-recover") null config.environment.systemPackages).text;
  labelOverlapMessage = "A label name served by more than one Podman runner must be listed in podmanCanary.sharedLabels and name the same image on each.";
  dockerOverlapMessage = "Podman runner label names, shared ones included, must not overlap Docker runner label names.";
in
  assert cleanupUnits cleanupOnly == [];
  assert cleanupUnits monitorOnly == [];
  assert cleanupUnits monitoredCleanup
  == [
    {
      name = "forgejo-idle-podman-cleanup.service";
      mode = "recent-success";
      maximumAgeSeconds = 1800;
      pendingFirstTimerMaximumAgeSeconds = 1320;
      allowPendingFirstTimer = true;
    }
  ];
  assert builtins.length monitoredCleanup.systemd.services.forgejo-idle-podman-cleanup.serviceConfig.ExecStopPost == 1;
  assert (lib.head (cleanupUnits hourlyCleanup)).maximumAgeSeconds == 7200;
  assert hourlyCleanup.systemd.timers.forgejo-idle-podman-cleanup.timerConfig.OnUnitActiveSec == "1h";
  assert !(cleanupOnly.systemd.services.forgejo-idle-podman-cleanup.serviceConfig ? ExecStopPost);
  assert !failedAssertion monitoredCleanup "storage-health-monitor recent-success units must be root-run oneshot services that become inactive after completion";
  assert !failedAssertion monitoredCleanup "Idle Podman cleanup requires the isolated Docker and Podman runners with disk-space admission control.";
  assert !(disabled.systemd.services ? forgejo-podman-runner);
  assert !(disabled.systemd.services ? forgejo-runner-podman);
  assert !(disabled.systemd.sockets ? forgejo-runner-podman);
  assert enabled.users.users.forgejo-podman-runner.group == "forgejo-podman";
  assert enabled.users.users.forgejo-podman-builder.group == "forgejo-podman";
  assert enabled.users.users.forgejo-podman-runner.home != enabled.users.users.forgejo-podman-builder.home;
  assert enabled.users.users.forgejo-podman-runner.home != enabled.users.users.forgejo-runner.home;
  assert api.serviceConfig.User == "forgejo-podman-builder";
  assert unit.serviceConfig.User == "forgejo-podman-runner";
  assert api.serviceConfig.Restart == "no";
  assert unit.serviceConfig.Restart == "on-failure";
  assert unit.serviceConfig.RestartSec == "30s";
  assert unit.restartIfChanged == false;
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
  assert lib.hasPrefix "+" enabled.systemd.services.forgejo-runner-docker.serviceConfig.ExecCondition;
  assert lib.hasPrefix "+" disabled.systemd.services.forgejo-runner-docker.serviceConfig.ExecCondition;
  assert disabled.systemd.services.forgejo-runner-docker.environment.PODMAN_ADMISSION == "0";
  assert !(lib.elem "forgejo-runner-aggregate-lifecycle.service" disabled.systemd.services.forgejo-runner-docker.after);
  assert !enabled.virtualisation.podman.dockerSocket.enable;
  assert !(unit.environment ? FIXTURE_SECRET);
  assert !(lib.hasInfix "FIXTURE_SECRET" unit.preStart);
  assert failedAssertion overlap "Podman CI canary label names must not overlap Docker runner label names.";
  assert failedAssertion hostLabel "Podman CI canary requires explicit name:docker://image labels.";
  # Without extra runners the list is the primary and the canary only.
  assert enabled.services.forgejo-actions-runner.runnerUnits == [primary canary];
  assert disabled.services.forgejo-actions-runner.runnerUnits == [primary];
  assert map (runner: runner.unit) enabled.services.nixfleet-boot-check.runnerUnits == [canary primary];
  # An extra runner joins every runner list after the canary, has its own
  # identity, state and configuration, and shares the account and API.
  assert failedAssertions three == failedAssertions enabled;
  assert three.services.forgejo-actions-runner.runnerUnits == [primary canary extra];
  assert lib.all (service: three.systemd.services.${service}.environment.RUNNER_UNITS == three-units) [
    "forgejo-runner-io-pressure-guard"
    "forgejo-runner-aggregate-lifecycle"
    "forgejo-actions-runner"
    "forgejo-podman-runner"
    "forgejo-podman-runner-fast"
    "forgejo-runner-podman"
  ];
  assert threeCleanup.systemd.services.forgejo-idle-podman-cleanup.environment.RUNNER_UNITS == three-units;
  assert cleanupOnly.systemd.services.forgejo-idle-podman-cleanup.environment.RUNNER_UNITS == both;
  # Fence recovery bakes the configured list in at build time.
  assert lib.hasInfix "\nRUNNER_UNITS=${lib.escapeShellArg three-units}\n" (recoveryText threeCleanup);
  assert lib.hasInfix "\nRUNNER_UNITS=${lib.escapeShellArg both}\n" (recoveryText cleanupOnly);
  assert extraUnit.environment.RUNNER_UNIT == extra;
  assert threeUnit.environment.RUNNER_UNIT == canary;
  assert extraUnit.description == "Forgejo Podman runner fast (fixture-fast)";
  assert extraUnit.serviceConfig.User == "forgejo-podman-runner";
  assert extraUnit.serviceConfig.Group == "forgejo-podman";
  assert extraUnit.serviceConfig.WorkingDirectory == "/var/lib/forgejo-podman-runner-fast";
  assert extraUnit.environment.HOME == "/var/lib/forgejo-podman-runner-fast";
  assert extraUnit.serviceConfig.RuntimeDirectory == "forgejo-podman-runner-fast";
  assert extraUnit.environment.DOCKER_HOST == threeUnit.environment.DOCKER_HOST;
  assert extraUnit.serviceConfig.ExecCondition == threeUnit.serviceConfig.ExecCondition;
  assert extraUnit.requires == threeUnit.requires && extraUnit.bindsTo == threeUnit.bindsTo && extraUnit.after == threeUnit.after;
  assert extraUnit.restartIfChanged == false;
  assert threeUnit.serviceConfig.WorkingDirectory == "/var/lib/forgejo-podman-runner";
  assert extraConfigFile != canaryConfigFile;
  # The extra registers its own identity into its own state with the
  # canary's token file by default.
  assert lib.hasInfix " /var/lib/forgejo-podman-runner-fast/.runner " extraUnit.preStart;
  assert lib.hasInfix " fixture-fast " extraUnit.preStart;
  assert lib.hasInfix "< /run/fixture/podman-registration-token" extraUnit.preStart;
  assert lib.hasInfix " ${fastLabel} " extraUnit.preStart;
  assert builtins.elem "d /var/lib/forgejo-podman-runner-fast 0750 forgejo-podman-runner forgejo-podman -" three.systemd.tmpfiles.rules;
  assert builtins.elem {
    unit = extra;
    holdMarkerDirectory = "/run/forgejo-runner-aggregate-pressure/runners/${extra}";
  }
  three.services.nixfleet-boot-check.runnerUnits;
  # ci-fast may be shared between Podman runners only when allowed and with
  # one image; the Docker runner never shares a label.
  assert failedAssertion sharedWithoutAllowance labelOverlapMessage;
  assert failedAssertion sharedDifferentImage labelOverlapMessage;
  assert failedAssertion sharedWithDocker dockerOverlapMessage;
  assert failedAssertion allowanceNamesDocker dockerOverlapMessage;
  assert failedAssertion extraHostLabel "Extra Podman runners require unique, explicit name:docker://image labels.";
  assert failedAssertion extraBadName "Extra Podman runner names must match ^[a-z0-9-]+$.";
  assert failedAssertion extraDuplicateName "Docker and Podman runner registration names must be distinct.";
  assert failedAssertion extraWithoutCanary "Extra Podman runners require the Podman CI canary.";
    pkgs.runCommand "forgejo-podman-canary-contract" {
      nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.shellcheck pkgs.systemd pkgs.util-linux];
    } ''
      shellcheck ${gateSource}
      # Each Podman runner has its own capacity, labels, state and env file.
      grep -Fxq '  capacity: 1' ${extraConfigFile}
      grep -Fxq '  - ${fastLabel}' ${extraConfigFile}
      grep -Fxq '  env_file: /run/forgejo-podman-runner-fast/job.env' ${extraConfigFile}
      grep -Fxq '  workdir_parent: /var/lib/forgejo-podman-runner-fast/host-work' ${extraConfigFile}
      grep -Fxq '  env_file: /run/forgejo-podman-runner/job.env' ${canaryConfigFile}
      grep -Fxq '  workdir_parent: /var/lib/forgejo-podman-runner/host-work' ${canaryConfigFile}
      if grep -Fq podman-canary ${extraConfigFile}; then exit 1; fi
      fixture="$(mktemp -d)"
      trap 'rm -rf "$fixture"' EXIT
      state="$fixture/state"
      mkdir -p "$state/runners/${canary}"
      chmod 700 "$state"
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
        STATE_DIR="$state" SYSTEMCTL_BIN="$fixture/systemctl" RUNNER_UNITS="''${GATE_UNITS:-${both}}" \
          bash ${gateSource} >/dev/null 2>&1
      }
      run_gate
      rm "$state/runner-units"
      if run_gate; then exit 1; fi
      printf '%s\n' ${lib.escapeShellArg primary} > "$state/runner-units"
      if run_gate; then exit 1; fi
      printf '%s\n' ${lib.escapeShellArg primary} ${lib.escapeShellArg canary} > "$state/runner-units"
      for marker in owned pending teardown-required cleanup-in-flight; do
        touch "$state/$marker"
        if run_gate; then exit 1; fi
        rm "$state/$marker"
      done
      ln -s "$state/missing" "$state/cleanup-in-flight"
      if run_gate; then exit 1; fi
      rm "$state/cleanup-in-flight"
      if MOCK_GUARD_ACTIVE=0 run_gate; then exit 1; fi
      if MOCK_FREEZER=frozen run_gate; then exit 1; fi
      run_gate

      # The primary runner leads and the existing Podman runner follows; any
      # extra Podman runner needs its own guard state directory.
      for units in ${lib.escapeShellArg primary} ${lib.escapeShellArg "${canary} ${primary}"} \
        ${lib.escapeShellArg "${primary} ${extra} ${canary}"}; do
        if GATE_UNITS=$units run_gate; then exit 1; fi
      done
      if GATE_UNITS=${lib.escapeShellArg three-units} run_gate; then exit 1; fi
      printf '%s\n' ${lib.escapeShellArg primary} ${lib.escapeShellArg canary} ${lib.escapeShellArg extra} > "$state/runner-units"
      if GATE_UNITS=${lib.escapeShellArg three-units} run_gate; then exit 1; fi
      if run_gate; then exit 1; fi
      mkdir "$state/runners/${extra}"
      GATE_UNITS=${lib.escapeShellArg three-units} run_gate
      if run_gate; then exit 1; fi
      touch "$state/cleanup-in-flight"
      if GATE_UNITS=${lib.escapeShellArg three-units} run_gate; then exit 1; fi
      rm "$state/cleanup-in-flight"
      rmdir "$state/runners/${canary}"
      if GATE_UNITS=${lib.escapeShellArg three-units} run_gate; then exit 1; fi
      mkdir "$state/runners/${canary}"
      GATE_UNITS=${lib.escapeShellArg three-units} run_gate
      touch "$out"
    ''
