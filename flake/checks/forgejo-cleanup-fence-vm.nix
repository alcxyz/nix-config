# Explicit, disposable lifecycle qualification using both production API units.
{pkgs}:
if pkgs.stdenv.hostPlatform.system != "x86_64-linux"
then pkgs.runCommand "forgejo-cleanup-fence-unsupported-platform" {} ''touch "$out"''
else
  pkgs.testers.runNixOSTest {
    name = "forgejo-cleanup-fence";
    nodes.machine = {lib, ...}: {
      imports = [../../modules/nixos/services/forgejo-actions-runner];
      options.sops.secrets = lib.mkOption {
        type = lib.types.attrs;
        default = {};
      };
      config = {
        system.stateVersion = "25.11";
        virtualisation = {
          memorySize = 2048;
          cores = 2;
          diskSize = 8192;
          docker.enable = true;
        };
        services.forgejo-actions-runner = {
          enable = true;
          name = "fence-fixture";
          labels = ["fixture:docker://example.invalid/unused:local"];
          secretsFile = pkgs.writeText "fixture-secrets" "unused";
          isolatedDocker.enable = true;
          ioPressureGuard = {
            admissionControl.enable = true;
            diskSpace = {
              enable = true;
              drainFreeGiB = 2;
              criticalFreeGiB = 1;
              recoveryFreeGiB = 3;
              drainFreePercent = 2;
              criticalFreePercent = 1;
              recoveryFreePercent = 3;
            };
          };
          idlePodmanCleanup.enable = true;
          podmanCanary = {
            enable = true;
            registrationTokenFile = toString (pkgs.writeText "fixture-registration-token" "unused");
            labels = ["podman-fixture:docker://example.invalid/unused:local"];
          };
        };
        services.storage-health-monitor = {
          enable = true;
          pingBaseFile = "/run/fixture-unused-ping";
        };
        systemd.timers.storage-health-monitor.wantedBy = lib.mkForce [];
        systemd.services.forgejo-idle-podman-cleanup.unitConfig.StartLimitIntervalSec = 0;
        systemd.timers.forgejo-idle-podman-cleanup.wantedBy = lib.mkForce [];
        # Repeated lifecycle trials run faster than the normal start-limit
        # interval. Qualify admission itself without this fixture exhausting it.
        systemd.sockets.forgejo-runner-podman.unitConfig.StartLimitIntervalSec = 0;
        systemd.services.forgejo-runner-docker.unitConfig.StartLimitIntervalSec = 0;
        systemd.services.forgejo-runner-podman.unitConfig.StartLimitIntervalSec = 0;
        systemd.services.fixture-pressure-init = {
          serviceConfig.Type = "oneshot";
          script = ''printf 'full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > /run/fixture-pressure'';
        };
        systemd.services.forgejo-runner-io-pressure-guard = {
          requires = ["fixture-pressure-init.service"];
          after = ["fixture-pressure-init.service"];
          environment.PRESSURE_FILE = "/run/fixture-pressure";
        };
        systemd.services.forgejo-actions-runner = {
          unitConfig.StartLimitIntervalSec = 0;
          preStart = lib.mkForce "";
          script = lib.mkForce "exec sleep infinity";
        };
        systemd.services.forgejo-podman-runner = {
          unitConfig.StartLimitIntervalSec = 0;
          preStart = lib.mkForce "";
          script = lib.mkForce "exec sleep infinity";
        };
        environment.systemPackages = [
          pkgs.docker
          pkgs.util-linux
          (pkgs.writeShellApplication {
            name = "fixture-cleanup-health";
            runtimeInputs = [pkgs.coreutils pkgs.gawk pkgs.systemd];
            text = "exec bash ${../../modules/nixos/services/storage-health-monitor/check-recent-success.sh} forgejo-idle-podman-cleanup.service 1800 true /var/lib/storage-health-monitor/success/${builtins.hashString "sha256" "forgejo-idle-podman-cleanup.service"} /proc/uptime";
          })
        ];
      };
    };
    nodes.dockerOnly = {lib, ...}: {
      imports = [../../modules/nixos/services/forgejo-actions-runner];
      options.sops.secrets = lib.mkOption {
        type = lib.types.attrs;
        default = {};
      };
      config = {
        system.stateVersion = "25.11";
        virtualisation = {
          memorySize = 1024;
          cores = 2;
          diskSize = 4096;
          docker.enable = true;
        };
        services.forgejo-actions-runner = {
          enable = true;
          name = "docker-only-fixture";
          labels = ["fixture:docker://example.invalid/unused:local"];
          secretsFile = pkgs.writeText "docker-only-fixture-secrets" "unused";
          isolatedDocker.enable = true;
        };
        systemd.services.forgejo-actions-runner = {
          preStart = lib.mkForce "";
          script = lib.mkForce "exec sleep infinity";
        };
        specialisation.changed.configuration.systemd.services.forgejo-actions-runner.environment.FIXTURE_GENERATION = "changed";
      };
    };
    testScript = ''
      import shlex
      state = "/run/forgejo-runner-aggregate-pressure"
      fence = state + "/cleanup-in-flight"
      runners = ["forgejo-actions-runner.service", "forgejo-podman-runner.service"]
      apis = ["forgejo-runner-docker.service", "forgejo-runner-podman.service"]
      recover = "/run/current-system/sw/bin/forgejo-runner-cleanup-fence-recover"

      def make_fence():
          machine.succeed(f"umask 077; mkdir -m 700 {fence}; printf 'cleanup-v2 123 123 0 POST /v5.0.0/libpod/containers/prune\\n' > {fence}/owner")
          for api in apis:
              generation = machine.succeed(f"systemctl show -p ExecMainStartTimestampMonotonic --value {api}").strip()
              assert int(generation) > 0
              machine.succeed(f"printf '%s\\n' '{api} {generation}' >> {fence}/api-generations")
          machine.succeed(f"chmod 600 {fence}/api-generations")

      def stop_units():
          machine.succeed("systemctl stop " + " ".join(runners + apis), timeout=180)
          machine.succeed("systemctl start forgejobuilds.slice")
          machine.succeed("test $(systemctl show -p FreezerState --value forgejobuilds.slice) = running")
          machine.succeed("test $(sed -n 's/^populated //p' /sys/fs/cgroup/forgejobuilds.slice/cgroup.events) = 0")

      def resume():
          machine.succeed("systemctl start " + " ".join(apis + runners), timeout=180)
          for unit in apis + runners:
              machine.wait_for_unit(unit)

      start_all()
      machine.wait_for_unit("multi-user.target")
      for unit in apis + runners:
          machine.wait_for_unit(unit)
      # Ordinary Docker-only boot and switch keep their original dependency
      # order and do not need the dual-runner registry or Podman health gate.
      dockerOnly.wait_for_unit("forgejo-actions-runner.service")
      dockerOnly.succeed(f'test "$(cat {state}/runner-units)" = forgejo-actions-runner.service')
      dockerOnly.succeed("systemctl stop forgejo-actions-runner.service forgejo-runner-docker.service", timeout=120)
      dockerOnly.succeed("/run/current-system/specialisation/changed/bin/switch-to-configuration test", timeout=180)
      dockerOnly.wait_for_unit("forgejo-actions-runner.service")
      dockerOnly.wait_for_unit("forgejo-runner-docker.service")
      assert "Found ordering cycle" not in dockerOnly.full_console_log
      assert "Found ordering cycle" not in machine.full_console_log
      machine.succeed("docker -H unix:///run/forgejo-docker/docker.sock info >/dev/null")
      machine.succeed("docker -H unix:///run/forgejo-podman/podman.sock info >/dev/null")

      # Actual systemd results override an earlier durable success. Legitimate
      # successful skips and the pending first timer remain healthy.
      cleanup = "forgejo-idle-podman-cleanup.service"
      marker = "/var/lib/storage-health-monitor/success/${builtins.hashString "sha256" "forgejo-idle-podman-cleanup.service"}"
      machine.succeed("systemctl start forgejo-idle-podman-cleanup.timer")
      machine.succeed("fixture-cleanup-health")
      machine.succeed("systemctl stop forgejo-idle-podman-cleanup.timer")
      machine.succeed("systemctl start " + cleanup)
      machine.succeed("fixture-cleanup-health")
      success = machine.succeed("cat " + marker)
      make_fence()
      for attempt in range(3):
          machine.fail("systemctl start " + cleanup)
          assert machine.succeed(f"systemctl show -p ExecMainStatus --value {cleanup}").strip() == "1"
          machine.fail("fixture-cleanup-health")
          assert machine.succeed("cat " + marker) == success
          machine.succeed("systemctl is-active --quiet forgejo-runner-io-pressure-guard.service")
      stop_units()
      machine.succeed(recover)
      machine.succeed("systemctl start " + cleanup)
      machine.succeed("fixture-cleanup-health")
      resume()

      success = machine.succeed("cat " + marker)
      # A systemd timeout during a destructive request creates the fence. The
      # request shim delays completion; actual systemd kills the whole cgroup.
      machine.succeed("systemctl stop " + " ".join(runners))
      df = "#!/bin/sh\nprintf 'Size Avail\\n100 20\\n'\n"
      curl = "#!${pkgs.bash}/bin/bash\nif [[ \"$*\" == *'/containers/prune'* ]]; then sleep 30; fi\nexec ${pkgs.curl}/bin/curl \"$@\"\n"
      machine.succeed("printf %s " + shlex.quote(df) + " > /run/cleanup-df; chmod +x /run/cleanup-df")
      machine.succeed("printf %s " + shlex.quote(curl) + " > /run/cleanup-curl; chmod +x /run/cleanup-curl")
      machine.succeed("mkdir -p /run/systemd/system/forgejo-idle-podman-cleanup.service.d")
      override = "[Service]\nEnvironment=DF_BIN=/run/cleanup-df CURL_BIN=/run/cleanup-curl CRITICAL_FREE_BYTES=0 CRITICAL_FREE_PERCENT=0\nTimeoutStartSec=5s\n"
      machine.succeed("printf %s " + shlex.quote(override) + " > /run/systemd/system/forgejo-idle-podman-cleanup.service.d/fixture.conf; systemctl daemon-reload")
      machine.fail("systemctl start " + cleanup)
      assert machine.succeed(f"systemctl show -p Result --value {cleanup}").strip() == "timeout"
      machine.succeed(f"test -d {fence}")
      machine.fail("fixture-cleanup-health")
      assert machine.succeed("cat " + marker) == success
      # Below-trigger disk samples cannot turn subsequent failures into success.
      df = "#!/bin/sh\nprintf 'Size Avail\\n100 90\\n'\n"
      machine.succeed("printf %s " + shlex.quote(df) + " > /run/cleanup-df")
      machine.succeed("mkdir -p /run/systemd/system/forgejo-idle-podman-cleanup.timer.d")
      timer = "[Timer]\nOnBootSec=\nOnUnitActiveSec=\nOnActiveSec=1s\nOnUnitInactiveSec=1s\nRandomizedDelaySec=0\nAccuracySec=1us\n"
      machine.succeed("printf %s " + shlex.quote(timer) + " > /run/systemd/system/forgejo-idle-podman-cleanup.timer.d/fixture.conf; systemctl daemon-reload")
      previous = machine.succeed(f"systemctl show -p ExecMainStartTimestampMonotonic --value {cleanup}").strip()
      machine.succeed("systemctl start forgejo-idle-podman-cleanup.timer")
      for attempt in range(3):
          machine.wait_until_succeeds(f"test $(systemctl show -p ExecMainStartTimestampMonotonic --value {cleanup}) != {previous} && test $(systemctl show -p ActiveState --value {cleanup}) = failed", timeout=10)
          previous = machine.succeed(f"systemctl show -p ExecMainStartTimestampMonotonic --value {cleanup}").strip()
          machine.fail("fixture-cleanup-health")
          assert machine.succeed("cat " + marker) == success
          machine.succeed("systemctl is-active --quiet forgejo-runner-io-pressure-guard.service")
      machine.succeed("systemctl stop forgejo-idle-podman-cleanup.timer")
      stop_units()
      machine.succeed(recover)
      machine.succeed("systemctl start " + cleanup)
      machine.succeed("fixture-cleanup-health")
      machine.succeed("rm /run/systemd/system/forgejo-idle-podman-cleanup.service.d/fixture.conf /run/systemd/system/forgejo-idle-podman-cleanup.timer.d/fixture.conf; systemctl daemon-reload")
      resume()

      # Real API executions: active generations cannot be recovered. Externally
      # stop the units, then fence-only recovery verifies systemd/kernel evidence.
      make_fence()
      machine.fail(recover)
      stop_units()
      for api in apis:
          machine.execute(f"systemctl start {api}")
          machine.fail(f"systemctl is-active --quiet {api}")
      machine.succeed("systemctl show -p ActiveState -p SubState -p ExecMainStartTimestampMonotonic " + " ".join(apis))
      machine.succeed(recover)
      resume()

      # An actual worker in the managed aggregate blocks terminal API snapshots.
      make_fence()
      stop_units()
      machine.succeed("systemd-run --unit=fence-worker --slice=forgejobuilds.slice sleep infinity")
      machine.fail(recover)
      machine.succeed("systemctl stop fence-worker.service")
      machine.succeed(recover)
      resume()

      # While recovery owns the lock, both real API ExecConditions enter the
      # activating/job state and wait on it. Recovery must refuse before removal.
      for api in apis:
          make_fence()
          stop_units()
          wrapper = "#!/bin/sh\nif test -e /run/recovery-pause; then touch /run/recovery-entered; while test -e /run/recovery-pause; do sleep 0.02; done; fi\nexec ${pkgs.systemd}/bin/systemctl \"$@\"\n"
          machine.succeed("printf %s " + shlex.quote(wrapper) + " > /run/recovery-systemctl; chmod +x /run/recovery-systemctl")
          machine.succeed("touch /run/recovery-pause; rm -f /run/recovery-entered /run/recovery-result")
          command = f"set +e; SYSTEMCTL_BIN=/run/recovery-systemctl {recover} >/run/recovery-log 2>&1; echo $? >/run/recovery-result"
          machine.succeed("systemd-run --unit=fence-recovery-fixture --collect /bin/sh -c " + shlex.quote(command))
          try:
              machine.wait_until_succeeds("test -e /run/recovery-entered", timeout=3)
          except Exception:
              machine.log(machine.succeed("cat /run/recovery-log /run/recovery-result"))
              raise
          machine.succeed(f"systemctl start --no-block {api}")
          machine.wait_until_succeeds(f"test $(systemctl show -p ControlPID --value {api}) != 0", timeout=3)
          machine.succeed("rm /run/recovery-pause")
          machine.wait_until_succeeds("test -e /run/recovery-result", timeout=5)
          machine.succeed("test $(cat /run/recovery-result) = 1")
          machine.wait_until_succeeds(f"test $(systemctl show -p ActiveState --value {api}) = inactive", timeout=10)
          machine.succeed(f"test -d {fence}")
          machine.succeed(recover)
          resume()

      # Gate passed, then a queued start remains activating in ExecStartPre.
      make_fence()
      stop_units()
      machine.succeed(f"mv {fence} /run/queued-fence")
      machine.succeed("mkdir -p /run/systemd/system/forgejo-runner-docker.service.d")
      machine.succeed("printf '[Service]\\nExecStartPre=+/bin/sh -c \"touch /run/api-passed; while test -e /run/api-pause; do sleep 0.02; done\"\\n' > /run/systemd/system/forgejo-runner-docker.service.d/fence-fixture.conf")
      machine.succeed("systemctl daemon-reload; touch /run/api-pause; systemctl start --no-block forgejo-runner-docker.service")
      machine.wait_until_succeeds("test -e /run/api-passed", timeout=10)
      machine.succeed(f"mv /run/queued-fence {fence}")
      machine.fail(recover)
      machine.succeed("systemctl stop --no-block forgejo-runner-docker.service; rm /run/api-pause")
      machine.wait_until_succeeds("case $(systemctl show -p ActiveState --value forgejo-runner-docker.service) in inactive|failed) ;; *) exit 1 ;; esac", timeout=30)
      stop_units()
      machine.succeed("rm /run/systemd/system/forgejo-runner-docker.service.d/fence-fixture.conf; systemctl daemon-reload")
      # A companion API may have executed before this artificial fence was
      # restored. Preserve it for reconciliation rather than changing its record.
      machine.succeed(f"test -d {fence}")
    '';
  }
