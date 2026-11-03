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
  dedicatedStorage = evaluate true validLabels {
    fileSystems."/var/lib/forgejo-podman" = {
      device = "fixture/runtime/podman";
      fsType = "zfs";
    };
    services.forgejo-actions-runner.podmanCanary.storageMountSource = "fixture/runtime/podman";
  };
  missingStorage = evaluate true validLabels {
    services.forgejo-actions-runner.podmanCanary.storageMountSource = "fixture/runtime/podman";
  };
  escapedStorage = evaluate true validLabels {
    fileSystems."/var/lib/forgejo-podman" = {
      device = "/dev/disk/by-label/CI\\x20Storage";
      fsType = "ext4";
    };
    services.forgejo-actions-runner.podmanCanary.storageMountSource = "/dev/disk/by-label/CI\\x20Storage";
  };
  overlap = evaluate true ["docker-primary:docker://example.invalid/different-image:latest"] {};
  hostLabel = evaluate true ["podman-canary:host"] {};
  resetConfig = {
    services.forgejo-actions-runner.podmanStoreReset.enable = true;
  };
  resetOnly = evaluate true validLabels resetConfig;
  resetWithoutPodman = evaluate false validLabels resetConfig;
  monitoredReset = evaluate true validLabels (lib.recursiveUpdate resetConfig {
    services.storage-health-monitor = {
      enable = true;
      pingBaseFile = "/run/fixture-unused-ping";
    };
  });
  lowPressureReset = evaluate true validLabels (lib.recursiveUpdate resetConfig {
    services.forgejo-actions-runner.podmanStoreReset.ioPressurePercent = 3;
  });
  # A game host: the runners get two minutes to finish, and the reset and the
  # gates read the game signal.
  gameReset = evaluate true validLabels (lib.recursiveUpdate resetConfig {
    services.gameSignal = {
      enable = true;
      user = "player";
      processNames = ["reaper"];
    };
    services.forgejo-actions-runner = {
      runnerHold.game.enable = true;
      shutdownTimeoutSeconds = 120;
    };
  });
  gameWithoutSignal = evaluate true validLabels {
    services.forgejo-actions-runner.runnerHold.game.enable = true;
  };
  monitorOnly = evaluate true validLabels {
    services.storage-health-monitor = {
      enable = true;
      pingBaseFile = "/run/fixture-unused-ping";
    };
  };
  resetUnits = config: builtins.filter (unit: unit.name == "forgejo-podman-store-reset.service") config.services.storage-health-monitor.units;
  resetService = config: config.systemd.services.forgejo-podman-store-reset;
  unit = enabled.systemd.services.forgejo-podman-runner;
  api = enabled.systemd.services.forgejo-runner-podman;
  socket = enabled.systemd.sockets.forgejo-runner-podman;
  hold = enabled.systemd.services.forgejo-runner-hold;
  dockerRunner = enabled.systemd.services.forgejo-actions-runner;
  failedAssertion = config: message:
    lib.any (entry: !entry.assertion && entry.message == message) config.assertions;
  failedAssertions = config: map (entry: entry.message) (builtins.filter (entry: !entry.assertion) config.assertions);
  gateSource = ../../modules/nixos/services/forgejo-actions-runner/podman-api-start-gate.sh;

  # A docker.io pull-through cache for both dedicated engines (#917).
  mirrorHost = "registry-cache.example.org";
  mirrorCa = ../../modules/nixos/services/forgejo-actions-runner/registry-cache-ca.crt;
  mirrored = evaluate true validLabels {
    services.forgejo-actions-runner = {
      registryMirror = mirrorHost;
      registryMirrorCaFile = mirrorCa;
    };
  };
  mirrorWithoutCa = evaluate true validLabels {services.forgejo-actions-runner.registryMirror = mirrorHost;};
  caWithoutMirror = evaluate true validLabels {services.forgejo-actions-runner.registryMirrorCaFile = mirrorCa;};
  dockerCaSetup = config: config.systemd.services.forgejo-runner-docker.serviceConfig.ExecStartPre;
  podmanCaSetup = config: config.systemd.services.forgejo-runner-podman.serviceConfig.ExecStartPre;
  etcCertsDirs = config: lib.filterAttrs (name: _: lib.hasInfix "certs.d" name) config.environment.etc;
  mirroredApi = mirrored.systemd.services.forgejo-runner-podman;
  v1Mirrored = evaluate true validLabels {
    services.forgejo-actions-runner.registryMirror = mirrorHost;
    virtualisation.containers.registries.search = ["docker.io"];
  };
  dockerConfigFile = config:
    lib.removePrefix "--config-file=" (lib.last (lib.splitString " " config.systemd.services.forgejo-runner-docker.serviceConfig.ExecStart));

  # The Podman runner serves ci-fast beside its pool label (ADR-0097) in one
  # registration, state and configuration.
  fastLabel = "ci-fast:docker://example.invalid/fast:latest";
  twoLabels = evaluate true (validLabels ++ [fastLabel]) {};
  twoLabelsUnit = twoLabels.systemd.services.forgejo-podman-runner;
  instanceScoped = evaluate true (validLabels ++ [fastLabel]) {
    services.forgejo-actions-runner.podmanCanary.registrationScope = "instance";
  };
  canaryConfigFile = lib.last (lib.splitString " " (lib.removeSuffix "\n" twoLabelsUnit.script));
  duplicateLabel = evaluate true (validLabels ++ ["podman-canary:docker://example.invalid/other:latest"]) {};
  duplicateName = evaluate true validLabels {
    services.forgejo-actions-runner.podmanCanary.name = lib.mkForce "fixture-docker";
  };
in
  assert !(enabled.systemd.services ? forgejo-podman-storage-ready);
  assert lib.elem "forgejo-podman-storage-ready.service" dedicatedStorage.systemd.services.forgejo-runner-podman.requires;
  assert lib.elem "forgejo-podman-storage-ready.service" dedicatedStorage.systemd.sockets.forgejo-runner-podman.requires;
  assert lib.elem "var-lib-forgejo\\x2dpodman.mount" dedicatedStorage.systemd.services.forgejo-runner-podman.bindsTo;
  assert lib.elem "var-lib-forgejo\\x2dpodman.mount" dedicatedStorage.systemd.sockets.forgejo-runner-podman.bindsTo;
  assert dedicatedStorage.systemd.services.forgejo-podman-storage-ready.serviceConfig.RemainAfterExit;
  assert lib.hasInfix "CI\\\\x20Storage" escapedStorage.systemd.services.forgejo-podman-storage-ready.serviceConfig.ExecStart;
  assert failedAssertion missingStorage "Dedicated Podman storage requires an explicit /var/lib/forgejo-podman filesystem.";
  assert resetUnits resetOnly == [];
  assert resetUnits monitorOnly == [];
  assert resetUnits monitoredReset
  == [
    {
      name = "forgejo-podman-store-reset.service";
      mode = "recent-success";
      maximumAgeSeconds = 10800;
      pendingFirstTimerMaximumAgeSeconds = 1320;
      allowPendingFirstTimer = true;
    }
  ];
  # The restart of what a failed run stopped comes first, then the health record.
  assert (resetService resetOnly).serviceConfig.ExecStopPost == ["${(resetService resetOnly).serviceConfig.ExecStart} restart"];
  assert builtins.length (resetService monitoredReset).serviceConfig.ExecStopPost == 2;
  assert lib.head (resetService monitoredReset).serviceConfig.ExecStopPost == "${(resetService monitoredReset).serviceConfig.ExecStart} restart";
  assert (resetService resetOnly).environment.IO_PRESSURE_THRESHOLD_HUNDREDTHS == "500";
  assert (resetService lowPressureReset).environment.IO_PRESSURE_THRESHOLD_HUNDREDTHS == "300";
  assert (resetService resetOnly).environment.STORE_PATH == resetOnly.services.forgejo-actions-runner.podmanCanary.storageRoot;
  assert (resetService resetOnly).environment.MAX_AGE_SECONDS == "604800";
  assert (resetService resetOnly).environment.TRIGGER_USED_PERCENT == "70";
  assert (resetService resetOnly).environment.QUIET_SECONDS == "900";
  # The reset waits for a runner stop as long as the stop itself may take.
  assert (resetService resetOnly).environment.RUNNER_STOP_TIMEOUT_SECONDS == "3900";
  assert (resetService gameReset).environment.RUNNER_STOP_TIMEOUT_SECONDS == "420";
  assert (resetService resetOnly).environment.GAME_ENABLED == "0";
  assert (resetService gameReset).environment.GAME_ENABLED == "1";
  assert (resetService gameReset).environment.GAME_FILE == "/run/game-signal/active";
  assert gameReset.systemd.services.forgejo-podman-runner.serviceConfig.TimeoutStopSec == "420s";
  assert gameReset.systemd.services.forgejo-actions-runner.serviceConfig.TimeoutStopSec == "420s";
  assert gameReset.systemd.services.forgejo-podman-runner.environment.GAME_ENABLED == "1";
  assert gameReset.systemd.services.forgejo-runner-hold.environment.GAME_ENABLED == "1";
  assert gameReset.systemd.services.forgejo-runner-hold.after == ["game-signal.service"];
  assert gameReset.systemd.services.game-signal.serviceConfig.Restart == "always";
  assert failedAssertion gameWithoutSignal "services.forgejo-actions-runner.runnerHold.game needs services.gameSignal.";
  assert !(resetService resetOnly).restartIfChanged;
  # Systemd ordering never excludes the reset: the start lock does, so a
  # start of another unit can never stop it mid-run.
  assert (resetService resetOnly).conflicts == [];
  assert (resetService resetOnly).after == [];
  assert !((resetService resetOnly).unitConfig ? Conflicts);
  assert resetOnly.systemd.timers.forgejo-podman-store-reset.timerConfig.OnUnitActiveSec == "15min";
  assert !(resetOnly.systemd.services ? forgejo-idle-podman-cleanup);
  assert !(resetOnly.systemd.services ? forgejo-runner-cleanup-fence-auto-recover);
  assert !(resetOnly.systemd.timers ? forgejo-runner-cleanup-fence-auto-recover);
  assert !failedAssertion monitoredReset "storage-health-monitor recent-success units must be root-run oneshot services that become inactive after completion";
  assert !failedAssertion resetOnly "The Podman store reset requires the isolated Docker and Podman runners.";
  assert failedAssertion resetWithoutPodman "The Podman store reset requires the isolated Docker and Podman runners.";
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
  assert hold.environment.RUNNER_UNITS == both;
  # Nothing binds to the runner hold: losing it stops no runner or engine.
  assert lib.all (service: service.bindsTo == []) [unit dockerRunner api];
  assert socket.bindsTo == ["forgejo-runner-podman.service"];
  assert !(socket.unitConfig ? ConditionPathExists);
  assert unit.requires == ["forgejo-runner-podman.service"];
  assert builtins.elem "forgejo-runner-hold.service" unit.wants;
  assert unit.serviceConfig.TimeoutStopSec == "3900s";
  assert unit.serviceConfig.KillMode == "mixed";
  assert unit.environment.STATE_DIR == "/run/forgejo-runner-hold";
  assert dockerRunner.environment.RUNNER_UNIT == primary;
  assert unit.environment.RUNNER_UNIT == canary;
  assert lib.hasPrefix "+" dockerRunner.serviceConfig.ExecCondition;
  assert lib.hasPrefix "+" unit.serviceConfig.ExecCondition;
  assert lib.hasPrefix "+" api.serviceConfig.ExecCondition;
  assert lib.hasPrefix "+" enabled.systemd.services.forgejo-runner-docker.serviceConfig.ExecCondition;
  assert lib.hasPrefix "+" disabled.systemd.services.forgejo-runner-docker.serviceConfig.ExecCondition;
  assert !(disabled.systemd.services.forgejo-runner-docker.environment ? PODMAN_ADMISSION);
  assert !enabled.virtualisation.podman.dockerSocket.enable;
  assert !(unit.environment ? FIXTURE_SECRET);
  assert !(lib.hasInfix "FIXTURE_SECRET" unit.preStart);
  assert failedAssertion overlap "Podman CI canary label names must not overlap Docker runner label names.";
  assert failedAssertion hostLabel "Podman CI canary requires explicit name:docker://image labels.";
  # The runner lists hold the primary and the Podman runner only.
  assert enabled.services.forgejo-actions-runner.runnerUnits == [primary canary];
  assert disabled.services.forgejo-actions-runner.runnerUnits == [primary];
  assert map (runner: runner.unit) enabled.services.nixfleet-boot-check.runnerUnits == [primary canary];
  assert builtins.elem {
    unit = canary;
    holdMarkerDirectory = "/run/forgejo-runner-hold/runners/${canary}";
  }
  enabled.services.nixfleet-boot-check.runnerUnits;
  assert builtins.elem "d /run/forgejo-runner-hold/runners/${canary} 0700 root root -" enabled.systemd.tmpfiles.rules;
  assert (resetService resetOnly).environment.RUNNER_UNITS == both;
  # A second label joins the same runner: no new unit, identity or state.
  assert failedAssertions twoLabels == failedAssertions enabled;
  assert twoLabels.services.forgejo-actions-runner.runnerUnits == [primary canary];
  assert twoLabels.systemd.services.forgejo-runner-hold.environment.RUNNER_UNITS == both;
  assert twoLabelsUnit.environment.RUNNER_UNIT == canary;
  assert twoLabelsUnit.description == "Forgejo Podman pool runner (fixture-podman)";
  assert twoLabelsUnit.serviceConfig.WorkingDirectory == "/var/lib/forgejo-podman-runner";
  assert twoLabelsUnit.environment.HOME == "/var/lib/forgejo-podman-runner";
  assert twoLabelsUnit.serviceConfig.RuntimeDirectory == "forgejo-podman-runner";
  assert builtins.elem "d /var/lib/forgejo-podman-runner 0750 forgejo-podman-runner forgejo-podman -" twoLabels.systemd.tmpfiles.rules;
  # The runner registers its own identity into its own state with its token
  # file, and passes both labels.
  assert lib.hasInfix " /var/lib/forgejo-podman-runner/.runner " twoLabelsUnit.preStart;
  assert lib.hasInfix " fixture-podman " twoLabelsUnit.preStart;
  assert lib.hasInfix "< /run/fixture/podman-registration-token" twoLabelsUnit.preStart;
  # Owner tokens pass no scope, so earlier registrations are kept; an instance
  # token passes its scope.
  assert lib.hasInfix " ${lib.head validLabels},${fastLabel} \\\n" twoLabelsUnit.preStart;
  assert lib.hasInfix ",${fastLabel} instance \\\n" instanceScoped.systemd.services.forgejo-podman-runner.preStart;
  assert instanceScoped.systemd.services.forgejo-actions-runner.preStart == twoLabels.systemd.services.forgejo-actions-runner.preStart;
  # Label names are unique on the Podman runner, and its registration name
  # differs from the Docker runner's.
  assert failedAssertion duplicateLabel "Podman CI canary label names must be unique.";
  assert failedAssertion duplicateName "Podman CI canary registration name must differ from the Docker runner name.";
  assert !(api.environment ? CONTAINERS_REGISTRIES_CONF);
  assert lib.hasPrefix "/nix/store/" mirroredApi.environment.CONTAINERS_REGISTRIES_CONF;
  assert failedAssertions mirrored == failedAssertions enabled;
  assert failedAssertion v1Mirrored "services.forgejo-actions-runner.registryMirror requires virtualisation.containers.registries.settings in the version 2 format.";
  assert !mirroredApi.restartIfChanged;
  # The CA is trusted for the mirror host only, in each engine's own certs.d,
  # never in /etc or the system trust store.
  assert etcCertsDirs mirrored == {};
  assert mirrored.security.pki.certificateFiles == enabled.security.pki.certificateFiles;
  assert failedAssertion caWithoutMirror "services.forgejo-actions-runner.registryMirrorCaFile requires registryMirror.";
  assert !mirrored.systemd.services.forgejo-runner-docker.restartIfChanged;
    pkgs.runCommand "forgejo-podman-canary-contract" {
      nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.python3 pkgs.shellcheck pkgs.systemd pkgs.util-linux pkgs.yq-go];
    } ''
      shellcheck ${gateSource}
      # The Podman runner has its own capacity, labels, state and env file.
      grep -Fxq '  capacity: 1' ${canaryConfigFile}
      grep -Fxq '  - ${lib.head validLabels}' ${canaryConfigFile}
      grep -Fxq '  - ${fastLabel}' ${canaryConfigFile}
      grep -Fxq '  env_file: /run/forgejo-podman-runner/job.env' ${canaryConfigFile}
      grep -Fxq '  workdir_parent: /var/lib/forgejo-podman-runner/host-work' ${canaryConfigFile}
      # The Podman runner sets no runner variables.
      if grep -Fq 'envs:' ${canaryConfigFile}; then exit 1; fi
      # The cache is a docker.io mirror in front of docker.io itself, so both
      # engines fall back to it; the host's other registries stay as they are.
      python3 - ${mirroredApi.environment.CONTAINERS_REGISTRIES_CONF} <<'PY'
      import sys, tomllib
      conf = tomllib.load(open(sys.argv[1], "rb"))
      assert conf["registry"] == [
          {"location": "docker.io", "mirror": [{"location": "${mirrorHost}"}]},
          {"location": "quay.io"},
      ], conf
      assert "unqualified-search-registries" not in conf, conf
      PY
      test "$(yq -o json -I0 '."registry-mirrors"' ${dockerConfigFile mirrored})" = '["https://${mirrorHost}"]'
      test "$(yq '."registry-mirrors"' ${dockerConfigFile enabled})" = null
      # Each engine rebuilds its per-host certs.d at start: with the CA for
      # the mirror host when set, and empty otherwise.
      check_ca_setup() {
        local script=$1 dir=$2 ca=$3
        grep -Fq "rm -rf -- $dir" "$script"
        if [[ -n $ca ]]; then
          grep -Fq "install -D -m 0644 $ca" "$script"
          grep -Fq "$dir/${mirrorHost}/ca.crt" "$script"
        elif grep -Fq install "$script"; then
          exit 1
        fi
      }
      docker_certs=/var/lib/forgejo-docker/.config/docker/certs.d
      podman_certs=/var/lib/forgejo-podman/.config/containers/certs.d
      check_ca_setup ${dockerCaSetup mirrored} "$docker_certs" ${mirrorCa}
      check_ca_setup ${podmanCaSetup mirrored} "$podman_certs" ${mirrorCa}
      check_ca_setup ${dockerCaSetup mirrorWithoutCa} "$docker_certs" ""
      check_ca_setup ${podmanCaSetup mirrorWithoutCa} "$podman_certs" ""
      check_ca_setup ${dockerCaSetup enabled} "$docker_certs" ""
      check_ca_setup ${podmanCaSetup enabled} "$podman_certs" ""
      # The API gate creates the hold state, refuses a symlink in its place
      # and waits for the start lock, which a store reset holds across its
      # rename.
      fixture="$(mktemp -d)"
      trap 'rm -rf "$fixture"' EXIT
      state="$fixture/state"
      STATE_DIR="$state" bash ${gateSource}
      test "$(stat -c %a "$state")" = 700
      ln -s "$state" "$fixture/link"
      if STATE_DIR="$fixture/link" bash ${gateSource}; then exit 1; fi
      flock "$state/start.lock" sleep 3 &
      sleep 1
      started=$SECONDS
      STATE_DIR="$state" bash ${gateSource}
      ((SECONDS - started >= 1))
      wait
      touch "$out"
    ''
