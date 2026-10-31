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
    services.forgejo-actions-runner.ioPressureGuard.lowPercent = 3;
  });
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
  guard = enabled.systemd.services.forgejo-runner-io-pressure-guard;
  lifecycle = enabled.systemd.services.forgejo-runner-aggregate-lifecycle;
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
  # A standby runner on one host and the status endpoint it reads on another.
  standbyUrl = "http://192.0.2.10:9478/";
  standby = withExtra validLabels {
    labels = [fastLabel];
    standby = {
      enable = true;
      statusUrl = standbyUrl;
    };
  } {};
  standbyUnit = standby.systemd.services.forgejo-podman-runner-fast;
  standbyController = standby.systemd.services.forgejo-podman-runner-fast-standby;
  status = withExtra validLabels {
    labels = [fastLabel];
    status = {
      enable = true;
      port = 9478;
      interface = "wt0";
    };
  } {};
  statusSocket = status.systemd.sockets.forgejo-podman-runner-fast-status;
  statusService = status.systemd.services."forgejo-podman-runner-fast-status@";
  standbyWithStatus = withExtra validLabels {
    labels = [fastLabel];
    standby = {
      enable = true;
      statusUrl = standbyUrl;
    };
    status = {
      enable = true;
      port = 9478;
      interface = "wt0";
    };
  } {};
  standbyNameClash = evaluate true validLabels {
    networking.hostName = "fixture";
    services.forgejo-actions-runner.podmanCanary.extraRunners = {
      fast = {
        labels = [fastLabel];
        standby = {
          enable = true;
          statusUrl = standbyUrl;
        };
      };
      fast-standby.labels = ["other:docker://example.invalid/other:latest"];
    };
  };
  statusNameClash = evaluate true validLabels {
    networking.hostName = "fixture";
    services.forgejo-actions-runner.podmanCanary.extraRunners = {
      fast = {
        labels = [fastLabel];
        status = {
          enable = true;
          port = 9478;
          interface = "wt0";
        };
      };
      fast-status.labels = ["other:docker://example.invalid/other:latest"];
    };
  };
  controllerSource = ../../modules/nixos/services/forgejo-actions-runner/standby-controller.sh;
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
  # The reset follows the guard's resume threshold, not a separate setting.
  assert (resetService resetOnly).environment.IO_PRESSURE_THRESHOLD_HUNDREDTHS == "500";
  assert (resetService lowPressureReset).environment.IO_PRESSURE_THRESHOLD_HUNDREDTHS == "300";
  assert (resetService resetOnly).environment.STORE_PATH == resetOnly.services.forgejo-actions-runner.podmanCanary.storageRoot;
  assert (resetService resetOnly).environment.MAX_AGE_SECONDS == "604800";
  assert (resetService resetOnly).environment.TRIGGER_USED_PERCENT == "70";
  assert !(resetService resetOnly).restartIfChanged;
  # Systemd ordering never excludes the reset: the lifecycle lock does, so a
  # start of another unit can never stop it mid-run.
  assert (resetService resetOnly).conflicts == [];
  assert (resetService resetOnly).after == [];
  assert !((resetService resetOnly).unitConfig ? Conflicts);
  assert resetOnly.systemd.timers.forgejo-podman-store-reset.timerConfig.OnUnitActiveSec == "15min";
  assert !(resetOnly.systemd.services ? forgejo-idle-podman-cleanup);
  assert !(resetOnly.systemd.services ? forgejo-runner-cleanup-fence-auto-recover);
  assert !(resetOnly.systemd.timers ? forgejo-runner-cleanup-fence-auto-recover);
  assert !failedAssertion monitoredReset "storage-health-monitor recent-success units must be root-run oneshot services that become inactive after completion";
  assert !failedAssertion resetOnly "The Podman store reset requires the isolated Docker and Podman runners with admission control.";
  assert failedAssertion resetWithoutPodman "The Podman store reset requires the isolated Docker and Podman runners with admission control.";
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
  # Only a standby runner's start gate waits for admission; its controller
  # reads the other host's status endpoint and keeps the unit enabled.
  assert failedAssertions standby == failedAssertions enabled;
  assert standbyUnit.environment.RUNNER_STANDBY == "1";
  assert standby.systemd.services.forgejo-podman-runner.environment.RUNNER_STANDBY == "0";
  assert extraUnit.environment.RUNNER_STANDBY == "0";
  assert standbyUnit.wantedBy == ["multi-user.target"];
  assert standbyUnit.serviceConfig.ExecCondition == threeUnit.serviceConfig.ExecCondition;
  assert standby.services.forgejo-actions-runner.runnerUnits == [primary canary extra];
  assert standbyController.environment.RUNNER_UNIT == extra;
  assert standbyController.environment.STATUS_URL == standbyUrl;
  assert standbyController.environment.STATUS_INTERFACE == "";
  assert standbyController.environment.POLL_SECONDS == "15";
  assert standbyController.environment.START_AFTER_POLLS == "5";
  assert standbyController.environment.STOP_AFTER_POLLS == "21";
  assert standbyController.serviceConfig.Restart == "always";
  assert standbyController.wantedBy == ["multi-user.target"];
  assert !(three.systemd.services ? forgejo-podman-runner-fast-standby);
  assert !(standby.systemd.sockets ? forgejo-podman-runner-fast-status);
  # The status endpoint answers only on the named interface and from the
  # allowed prefixes, in a throwaway unprivileged service.
  assert failedAssertions status == failedAssertions enabled;
  assert !(status.systemd.services ? forgejo-podman-runner-fast-standby);
  assert status.systemd.services.forgejo-podman-runner-fast.environment.RUNNER_STANDBY == "0";
  assert statusSocket.listenStreams == ["9478"];
  assert statusSocket.socketConfig.Accept;
  assert statusSocket.socketConfig.IPAddressAllow == ["100.64.0.0/10"];
  assert statusSocket.socketConfig.IPAddressDeny == "any";
  assert status.networking.firewall.interfaces.wt0.allowedTCPPorts == [9478];
  assert !(builtins.elem 9478 status.networking.firewall.allowedTCPPorts);
  assert statusService.serviceConfig.DynamicUser;
  assert statusService.serviceConfig.StandardInput == "socket";
  assert statusService.serviceConfig.RestrictAddressFamilies == "AF_UNIX";
  assert failedAssertion standbyWithStatus "A standby Podman runner cannot also publish a status endpoint.";
  assert failedAssertion standbyNameClash "A standby controller's or status endpoint's unit name must not match a Podman runner's.";
  assert failedAssertion statusNameClash "A standby controller's or status endpoint's unit name must not match a Podman runner's.";
  assert !standbyController.restartIfChanged;
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
      shellcheck ${controllerSource}
      python3 ${./test-forgejo-standby-controller.py} ${controllerSource}
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
      for marker in owned pending teardown-required; do
        touch "$state/$marker"
        if run_gate; then exit 1; fi
        rm "$state/$marker"
      done
      # A completion fence left from before ADR-0105 no longer holds a start.
      mkdir "$state/cleanup-in-flight"
      run_gate
      rmdir "$state/cleanup-in-flight"
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
      rmdir "$state/runners/${canary}"
      if GATE_UNITS=${lib.escapeShellArg three-units} run_gate; then exit 1; fi
      mkdir "$state/runners/${canary}"
      GATE_UNITS=${lib.escapeShellArg three-units} run_gate
      touch "$out"
    ''
