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
  threeReset = withExtra validLabels {labels = [fastLabel];} resetConfig;
  extraUnit = three.systemd.services.forgejo-podman-runner-fast;
  threeUnit = three.systemd.services.forgejo-podman-runner;
  # An instance token on the canary carries over to the extra unless it sets
  # its own scope.
  instanceScoped = withExtra (validLabels ++ [fastLabel]) {labels = [fastLabel];} (lib.recursiveUpdate sharedConfig {
    services.forgejo-actions-runner.podmanCanary.registrationScope = "instance";
  });
  ownerExtra =
    withExtra (validLabels ++ [fastLabel]) {
      labels = [fastLabel];
      registrationScope = "owner";
    } (lib.recursiveUpdate sharedConfig {
      services.forgejo-actions-runner.podmanCanary.registrationScope = "instance";
    });
  extraConfigFile = lib.last (lib.splitString " " (lib.removeSuffix "\n" extraUnit.script));
  canaryConfigFile = lib.last (lib.splitString " " (lib.removeSuffix "\n" threeUnit.script));
  # The Nix cache proxy (ADR-0103) gives every Podman runner's jobs its
  # NIX_CONFIG and runs only beside the Podman pool, behind the iptables guard.
  proxyConfig = {services.forgejo-actions-runner.nixCacheProxy.enable = true;};
  proxied = withExtra (validLabels ++ [fastLabel]) {labels = [fastLabel];} (lib.recursiveUpdate sharedConfig proxyConfig);
  proxiedConfigFiles = map (name: lib.last (lib.splitString " " (lib.removeSuffix "\n" proxied.systemd.services.${name}.script))) ["forgejo-podman-runner" "forgejo-podman-runner-fast"];
  proxyWithoutCanary = evaluate false validLabels proxyConfig;
  # NixOS's default cache.nixos.org entry, an explicit one without the
  # trailing slash and one with store parameters are one upstream; entries
  # with a port and SSH substituters are not proxied.
  proxyFleetCaches = evaluate true validLabels (proxyConfig
    // {
      nix.settings.substituters = lib.mkForce [
        "https://cache.nixos.org/"
        "https://cache.nixos.org"
        "https://cache.nixos.org?priority=40"
        "https://nix-community.cachix.org/?trusted=1"
        "https://ported.invalid:8443"
        "ssh://builder.invalid"
      ];
    });
  fleetProxy = proxyFleetCaches.services.forgejo-actions-runner.nixCacheProxy;
  # An explicit upstream with a query, port, fragment or trailing slash is
  # rejected; list elements are checked lazily, hence deepSeq.
  upstreamAccepted = url: let
    upstreams =
      (evaluate true validLabels (lib.recursiveUpdate proxyConfig {
        services.forgejo-actions-runner.nixCacheProxy.upstreams = [url];
      }))
      .services
      .forgejo-actions-runner
      .nixCacheProxy
      .upstreams;
  in
    (builtins.tryEval (builtins.deepSeq upstreams upstreams)).success;
  badUpstream = url: !(upstreamAccepted url);
  proxyWithoutIPv6 = evaluate true validLabels (proxyConfig // {networking.enableIPv6 = false;});
  proxyOnNftables = evaluate true validLabels (proxyConfig // {networking.nftables.enable = true;});
  # firewalld does not run the NixOS firewall's hooks, whatever its backend.
  proxyOnFirewalld = evaluate true validLabels (lib.recursiveUpdate proxyConfig {services.firewalld.enable = true;});
  proxyWithJobNixConfig = evaluate true validLabels (lib.recursiveUpdate proxyConfig {
    services.forgejo-actions-runner.podmanCanary.jobEnv.NIX_CONFIG = "fallback = false";
  });
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
  labelOverlapMessage = "A label name served by more than one Podman runner must be listed in podmanCanary.sharedLabels and name the same image on each.";
  dockerOverlapMessage = "Podman runner label names, shared ones included, must not overlap Docker runner label names.";
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
  # Without extra runners the list is the primary and the canary only.
  assert enabled.services.forgejo-actions-runner.runnerUnits == [primary canary];
  assert disabled.services.forgejo-actions-runner.runnerUnits == [primary];
  assert map (runner: runner.unit) enabled.services.nixfleet-boot-check.runnerUnits == [primary canary];
  # An extra runner joins every runner list after the canary, has its own
  # identity, state and configuration, and shares the account and API.
  assert failedAssertions three == failedAssertions enabled;
  assert three.services.forgejo-actions-runner.runnerUnits == [primary canary extra];
  assert three.systemd.services.forgejo-runner-hold.environment.RUNNER_UNITS == three-units;
  assert builtins.elem "d /run/forgejo-runner-hold/runners/${extra} 0700 root root -" three.systemd.tmpfiles.rules;
  assert (resetService threeReset).environment.RUNNER_UNITS == three-units;
  assert (resetService resetOnly).environment.RUNNER_UNITS == both;
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
  # Owner tokens pass no scope, so earlier registrations are kept; an instance
  # token passes its scope to every runner that uses it.
  assert lib.hasInfix " ${fastLabel} \\\n" extraUnit.preStart;
  assert lib.hasInfix " ${fastLabel} instance \\\n" instanceScoped.systemd.services.forgejo-podman-runner-fast.preStart;
  assert lib.hasInfix ",${fastLabel} instance \\\n" instanceScoped.systemd.services.forgejo-podman-runner.preStart;
  assert lib.hasInfix " ${fastLabel} \\\n" ownerExtra.systemd.services.forgejo-podman-runner-fast.preStart;
  assert instanceScoped.systemd.services.forgejo-actions-runner.preStart == three.systemd.services.forgejo-actions-runner.preStart;
  assert builtins.elem "d /var/lib/forgejo-podman-runner-fast 0750 forgejo-podman-runner forgejo-podman -" three.systemd.tmpfiles.rules;
  assert builtins.elem {
    unit = extra;
    holdMarkerDirectory = "/run/forgejo-runner-hold/runners/${extra}";
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
  assert failedAssertions proxied == failedAssertions three;
  assert !proxied.services.ncps.enable && !(proxied.systemd.services ? ncps);
  assert proxied.systemd.services.forgejo-nix-cache.wantedBy == ["multi-user.target"];
  assert !(enabled.systemd.services ? forgejo-nix-cache);
  assert proxied.systemd.services.forgejo-nix-cache.unitConfig.RequiresMountsFor == ["/var/lib/forgejo-nix-cache"];
  assert proxied.services.forgejo-actions-runner.nixCacheProxy.upstreams == ["https://cache.nixos.org"];
  assert fleetProxy.upstreams == ["https://cache.nixos.org" "https://nix-community.cachix.org"];
  assert lib.hasInfix "extra-substituters = http://host.containers.internal:8501/cache.nixos.org?priority=10 http://host.containers.internal:8501/nix-community.cachix.org?priority=11\n" fleetProxy.jobNixConfig;
  assert lib.hasInfix "iptables -w -t raw -A forgejo-nix-cache -p tcp --dport 8501 -m addrtype --dst-type LOCAL ! --src-type LOCAL -j DROP" proxied.networking.firewall.extraCommands;
  assert lib.hasInfix "ip6tables -w -t raw -A forgejo-nix-cache -p tcp --dport 8501 -m addrtype --dst-type LOCAL ! --src-type LOCAL -j DROP" proxied.networking.firewall.extraCommands;
  assert !(builtins.elem 8501 proxied.networking.firewall.allowedTCPPorts);
  # Without IPv6 no ip6tables call can break the firewall start.
  assert lib.hasInfix "iptables -w -t raw -A forgejo-nix-cache" proxyWithoutIPv6.networking.firewall.extraCommands;
  assert !(lib.hasInfix "ip6tables" proxyWithoutIPv6.networking.firewall.extraCommands);
  assert failedAssertion proxyWithoutCanary "The CI Nix cache proxy serves the Podman runner pool and requires podmanCanary.enable.";
  assert failedAssertion proxyOnNftables "The CI Nix cache proxy requires the iptables NixOS firewall, which installs the rule refusing its port to other hosts.";
  assert failedAssertion proxyOnFirewalld "The CI Nix cache proxy requires the iptables NixOS firewall, which installs the rule refusing its port to other hosts.";
  assert upstreamAccepted "https://cache.example/sub/path";
  assert lib.all badUpstream [
    "https://cache.nixos.org?priority=40"
    "https://cache.nixos.org:443"
    "https://cache.nixos.org/#x"
    "https://cache.nixos.org/"
  ];
  assert proxied.systemd.paths.forgejo-nix-cache-resolver.pathConfig.PathChanged == "/etc/resolv.conf";
  assert lib.hasInfix "forgejo-nix-cache-resolver" (toString proxied.systemd.services.forgejo-nix-cache.serviceConfig.ExecStartPre);
  assert failedAssertion proxyWithJobNixConfig "podmanCanary.jobEnv must not set NIX_CONFIG while the CI Nix cache proxy supplies it.";
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
      # Each Podman runner has its own capacity, labels, state and env file.
      grep -Fxq '  capacity: 1' ${extraConfigFile}
      grep -Fxq '  - ${fastLabel}' ${extraConfigFile}
      grep -Fxq '  env_file: /run/forgejo-podman-runner-fast/job.env' ${extraConfigFile}
      grep -Fxq '  workdir_parent: /var/lib/forgejo-podman-runner-fast/host-work' ${extraConfigFile}
      grep -Fxq '  env_file: /run/forgejo-podman-runner/job.env' ${canaryConfigFile}
      grep -Fxq '  workdir_parent: /var/lib/forgejo-podman-runner/host-work' ${canaryConfigFile}
      if grep -Fq podman-canary ${extraConfigFile}; then exit 1; fi
      # With the Nix cache proxy, every Podman runner hands its jobs the
      # proxy's NIX_CONFIG; without it, no runner sets runner variables.
      for file in ${lib.escapeShellArgs proxiedConfigFiles}; do
        test "$(yq '.runner.envs.NIX_CONFIG' "$file")" = ${lib.escapeShellArg (lib.removeSuffix "\n" proxied.services.forgejo-actions-runner.nixCacheProxy.jobNixConfig)}
        grep -Fq 'extra-substituters = http://host.containers.internal:8501/cache.nixos.org?priority=10' "$file"
      done
      if grep -Fq 'envs:' ${canaryConfigFile} ${extraConfigFile}; then exit 1; fi
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
