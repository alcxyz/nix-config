# Disposable integration qualification for the opt-in Podman runner beside
# the production isolated-Docker runner. It does not register with Forgejo.
{pkgs}: let
  busybox = pkgs.pkgsStatic.busybox;
  workerImage = pkgs.dockerTools.buildLayeredImage {
    name = "forgejo-coexistence-worker";
    tag = "local";
    contents = [busybox];
    config = {
      Cmd = [
        "/bin/busybox"
        "sh"
        "-c"
        "while :; do sleep 1; done"
      ];
      Env = ["PATH=/bin:/usr/bin"];
    };
  };
  unusedSecrets = pkgs.writeText "forgejo-coexistence-secrets" "fixture-only";
  registrationToken = pkgs.writeText "forgejo-coexistence-registration-token" "unused-fixture-token";
in
  pkgs.testers.runNixOSTest {
    name = "forgejo-podman-coexistence";
    nodes.machine = {lib, ...}: {
      imports = [../../modules/nixos/services/forgejo-actions-runner];
      options.sops.secrets = lib.mkOption {
        type = lib.types.attrs;
        default = {};
      };
      config = {
        system.stateVersion = "25.11";
        virtualisation = {
          memorySize = 3072;
          cores = 2;
          diskSize = 6144;
          docker.enable = true;
        };
        services.forgejo-actions-runner = {
          enable = true;
          name = "coexistence-fixture";
          labels = ["fixture:docker://example.invalid/unused:local"];
          secretsFile = unusedSecrets;
          isolatedDocker.enable = true;
          resourcePolicy = {
            memoryHigh = "1800M";
            memoryMax = "2200M";
          };
          ioPressureGuard = {
            admissionControl.enable = true;
            highPercent = 20;
            lowPercent = 5;
            highDurationSeconds = 1;
            lowDurationSeconds = 1;
            sampleSeconds = 1;
            transitionTimeoutSeconds = 20;
            admissionControl.severePercent = 80;
            admissionControl.severeDurationSeconds = 1;
          };
          podmanCanary = {
            enable = true;
            registrationTokenFile = toString registrationToken;
            labels = ["podman-fixture:docker://example.invalid/unused:local"];
          };
        };
        systemd.services.fixture-pressure-init = {
          description = "Initialize disposable pressure input before the guard";
          serviceConfig.Type = "oneshot";
          script = ''
            printf 'full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > /run/fixture-pressure
          '';
        };
        systemd.services.forgejo-runner-io-pressure-guard = {
          requires = ["fixture-pressure-init.service"];
          after = ["fixture-pressure-init.service"];
          environment.PRESSURE_FILE = "/run/fixture-pressure";
        };
        # Keep the production units and dependencies while bypassing remote
        # runner registration, as in the existing Docker VM.
        systemd.services.forgejo-actions-runner.preStart = lib.mkForce "";
        systemd.services.forgejo-actions-runner.script = lib.mkForce ''
          trap 'while test -e /run/fixture-runner-block-stop; do sleep 1; done; exit 0' TERM
          while :; do sleep 1; done
        '';
        systemd.services.forgejo-podman-runner.preStart = lib.mkForce "";
        systemd.services.forgejo-podman-runner.script = lib.mkForce ''
          trap 'while test -e /run/fixture-runner-block-stop; do sleep 1; done; exit 0' TERM
          while :; do sleep 1; done
        '';
        specialisation.changed.configuration.systemd.services.forgejo-actions-runner.environment.FIXTURE_GENERATION = "changed";
        specialisation.changed.configuration.systemd.services.forgejo-podman-runner.environment.FIXTURE_GENERATION = "changed";
        environment.systemPackages = [
          pkgs.docker
          pkgs.procps
        ];
      };
    };
    testScript = ''
      docker = "docker -H unix:///run/forgejo-docker/docker.sock"
      podman = "docker -H unix:///run/forgejo-podman/podman.sock"
      pressure = lambda value, n: f"printf 'full avg10={value}.00 avg60={value}.00 avg300={value}.00 total={n}\\n' > /run/fixture-pressure"
      worker = "/bin/busybox sh -c 'while :; do sleep 1; done'"
      worker_serial = 0

      def workers():
          global worker_serial
          worker_serial += 1
          docker_name = f"docker-worker-{worker_serial}"
          podman_name = f"podman-worker-{worker_serial}"
          machine.succeed(f"{docker} run -d --name {docker_name} forgejo-coexistence-worker:local {worker}")
          machine.succeed(f"{podman} run -d --name {podman_name} forgejo-coexistence-worker:local {worker}")
          docker_pid = machine.succeed(f"{docker} inspect --format '{{{{.State.Pid}}}}' {docker_name}").strip()
          podman_pid = machine.succeed(f"{podman} inspect --format '{{{{.State.Pid}}}}' {podman_name}").strip()
          assert "forgejobuilds.slice/forgejo-runner-docker.service" in machine.succeed(f"cat /proc/{docker_pid}/cgroup")
          assert "forgejobuilds.slice/forgejo-runner-podman.service" in machine.succeed(f"cat /proc/{podman_pid}/cgroup")
          return docker_pid, podman_pid

      def assert_worker_alive(pid):
          machine.succeed(f"test -e /proc/{pid}")

      start_all()
      machine.wait_for_unit("multi-user.target")
      assert not any("Found ordering cycle" in line for line in machine.full_console_log)
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-actions-runner.service", timeout=60)
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-podman-runner.service", timeout=60)
      machine.succeed("systemctl restart forgejo-actions-runner.service forgejo-podman-runner.service", timeout=120)
      machine.succeed("systemctl is-active forgejo-actions-runner.service forgejo-podman-runner.service")
      machine.succeed("systemctl is-active forgejo-runner-io-pressure-guard.service")
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-runner-aggregate-lifecycle.service", timeout=60)
      machine.succeed("systemctl is-active docker.service")
      machine.succeed("docker info >/dev/null")
      assert machine.succeed("systemctl show forgejobuilds.slice -p CPUQuotaPerSecUSec --value").strip() == "1s"
      assert machine.succeed("cat /sys/fs/cgroup/forgejobuilds.slice/memory.high").strip() == str(1800 * 1024 * 1024)
      assert machine.succeed("cat /sys/fs/cgroup/forgejobuilds.slice/memory.max").strip() == str(2200 * 1024 * 1024)
      machine.succeed(f"{docker} info >/dev/null")
      machine.succeed(f"{podman} info >/dev/null")
      machine.succeed(f"{docker} load < ${workerImage}")
      machine.succeed(f"{podman} load < ${workerImage}")

      # Moderate pressure stops both pollers but lets admitted workers finish;
      # low pressure resumes only units the guard itself stopped.
      docker_pid, podman_pid = workers()
      machine.succeed(pressure(30, 1))
      machine.wait_until_succeeds("test -e /run/forgejo-runner-aggregate-pressure/drain-owned && test -e /run/forgejo-runner-aggregate-pressure/runners/forgejo-podman-runner.service/drain-owned")
      machine.wait_until_succeeds("! systemctl is-active --quiet forgejo-actions-runner.service && ! systemctl is-active --quiet forgejo-podman-runner.service")
      assert_worker_alive(docker_pid)
      assert_worker_alive(podman_pid)
      machine.succeed(pressure(0, 2))
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-actions-runner.service", timeout=60)
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-podman-runner.service", timeout=60)
      machine.wait_until_succeeds("test ! -e /run/forgejo-runner-aggregate-pressure/drain-owned && test ! -e /run/forgejo-runner-aggregate-pressure/runners/forgejo-podman-runner.service/drain-owned")

      # Severe pressure freezes both backends under the same aggregate; recovery
      # thaws the aggregate before either runner is admitted again.
      machine.succeed(pressure(99, 3))
      machine.wait_until_succeeds("test $(systemctl show forgejobuilds.slice -p FreezerState --value) = frozen")
      machine.succeed("test -e /run/forgejo-runner-aggregate-pressure/owned")
      assert_worker_alive(docker_pid)
      assert_worker_alive(podman_pid)
      machine.succeed(pressure(0, 4))
      machine.wait_until_succeeds("test $(systemctl show forgejobuilds.slice -p FreezerState --value) = running")
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-actions-runner.service", timeout=60)
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-podman-runner.service", timeout=60)

      # A canary that an operator stopped is never restarted by low-pressure
      # recovery, while the guard-owned Docker runner is resumed.
      machine.succeed("systemctl stop forgejo-podman-runner.service")
      machine.succeed(pressure(30, 5))
      machine.wait_until_succeeds("test -e /run/forgejo-runner-aggregate-pressure/drain-owned")
      machine.succeed(pressure(0, 6))
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-actions-runner.service", timeout=60)
      machine.succeed("! systemctl is-active --quiet forgejo-podman-runner.service")
      machine.succeed("systemctl start forgejo-podman-runner.service")
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-podman-runner.service", timeout=60)

      # A NixOS switch while both units are guard-drained preserves ownership
      # and cannot create a new runner generation.
      machine.succeed(pressure(30, 7))
      machine.wait_until_succeeds("test -e /run/forgejo-runner-aggregate-pressure/drain-owned && test -e /run/forgejo-runner-aggregate-pressure/runners/forgejo-podman-runner.service/drain-owned")
      machine.succeed("test -x /run/current-system/specialisation/changed/bin/switch-to-configuration")
      machine.succeed("/run/current-system/specialisation/changed/bin/switch-to-configuration switch", timeout=180)
      machine.succeed("test $(systemctl show forgejo-actions-runner.service -p ActiveState --value) = inactive")
      machine.succeed("test $(systemctl show forgejo-podman-runner.service -p ActiveState --value) = inactive")
      machine.succeed("test -e /run/forgejo-runner-aggregate-pressure/drain-owned && test -e /run/forgejo-runner-aggregate-pressure/runners/forgejo-podman-runner.service/drain-owned")
      machine.succeed(pressure(0, 8))
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-actions-runner.service", timeout=60)
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-podman-runner.service", timeout=60)

      # Losing the shared guard while workers are frozen tears down both API
      # daemons and both workers; the host Docker daemon remains available.
      docker_pid, podman_pid = workers()
      machine.succeed(pressure(99, 9))
      machine.wait_until_succeeds("test $(systemctl show forgejobuilds.slice -p FreezerState --value) = frozen")
      machine.succeed("systemctl kill --signal=KILL --kill-whom=all forgejo-runner-io-pressure-guard.service")
      machine.wait_until_succeeds("! systemctl is-active --quiet forgejo-runner-docker.service && ! systemctl is-active --quiet forgejo-runner-podman.service", timeout=150)
      machine.wait_until_succeeds("test $(systemctl show forgejobuilds.slice -p FreezerState --value) = running", timeout=150)
      machine.fail(f"test -e /proc/{docker_pid}")
      machine.fail(f"test -e /proc/{podman_pid}")
      machine.succeed("! systemctl is-active --quiet forgejo-runner-podman.socket")
      machine.succeed("systemctl is-active docker.service")
      machine.succeed("docker info >/dev/null")

      # Clear only fixture-owned teardown state to exercise systemd shutdown
      # semantics after guard-loss recovery.
      machine.succeed(pressure(0, 10))
      machine.succeed("rm -f /run/forgejo-runner-aggregate-pressure/teardown-required /run/forgejo-runner-aggregate-pressure/owned")
      machine.succeed("systemctl reset-failed forgejo-runner-io-pressure-guard.service forgejo-runner-docker.service forgejo-runner-podman.service forgejo-runner-aggregate-lifecycle.service")
      machine.succeed("systemctl start forgejo-runner-docker.service forgejo-runner-podman.service", timeout=150)
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-runner-aggregate-lifecycle.service", timeout=60)
      machine.wait_until_succeeds("test $(systemctl show forgejobuilds.slice -p FreezerState --value) = running")
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-actions-runner.service", timeout=60)
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-podman-runner.service", timeout=60)
      machine.wait_until_succeeds("test ! -e /run/forgejo-runner-aggregate-pressure/drain-owned && test ! -e /run/forgejo-runner-aggregate-pressure/runners/forgejo-podman-runner.service/drain-owned")

      # An unexpected API exit must close its activation socket. A late
      # client must not resurrect the API after lifecycle teardown starts.
      machine.succeed("systemctl kill --signal=KILL --kill-whom=main forgejo-runner-podman.service")
      machine.wait_until_succeeds("! systemctl is-active --quiet forgejo-runner-podman.service && ! systemctl is-active --quiet forgejo-runner-podman.socket", timeout=90)
      machine.fail(f"timeout 5 {podman} info >/dev/null 2>&1", timeout=15)
      machine.succeed("! systemctl is-active --quiet forgejo-runner-podman.service")
      machine.succeed("! systemctl is-active --quiet forgejo-runner-podman.socket")
      machine.succeed("systemctl is-active docker.service")
      machine.succeed("systemctl reset-failed forgejo-runner-podman.service forgejo-runner-docker.service forgejo-runner-aggregate-lifecycle.service")
      machine.succeed("systemctl start forgejo-runner-docker.service forgejo-runner-podman.service", timeout=150)
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-runner-aggregate-lifecycle.service", timeout=60)
      machine.succeed("systemctl start forgejo-actions-runner.service forgejo-podman-runner.service", timeout=90)
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-actions-runner.service && systemctl is-active --quiet forgejo-podman-runner.service", timeout=60)

      workers()
      machine.succeed("touch /run/fixture-runner-block-stop")
      machine.succeed(pressure(99, 10))
      machine.wait_until_succeeds("test $(systemctl show forgejobuilds.slice -p FreezerState --value) = frozen && test -e /run/forgejo-runner-aggregate-pressure/owned")
      owned_log_start = len(machine.full_console_log)
      machine.shutdown()
      owned_log = machine.full_console_log[owned_log_start:]
      assert any("forgejobuilds.slice: Unit now thawed." in line for line in owned_log)
      assert any("forgejo-runner-aggregate-lifecycle.service: Deactivated successfully." in line for line in owned_log)
      assert not any("aggregate lifecycle:" in line for line in owned_log)
      assert not any("Cannot stop frozen unit" in line for line in owned_log)

      # Manual and ambiguous freezes are preserved during bounded shutdown.
      machine.start()
      machine.wait_for_unit("multi-user.target")
      assert not any("Found ordering cycle" in line for line in machine.full_console_log)
      machine.succeed("systemctl start forgejo-runner-docker.service forgejo-runner-podman.service", timeout=150)
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-runner-aggregate-lifecycle.service", timeout=60)
      workers()
      machine.succeed("systemctl freeze forgejobuilds.slice")
      manual_log_start = len(machine.full_console_log)
      assert machine.shell is not None
      machine.shell.send(b"poweroff\n")
      assert machine.process is not None
      machine.process.wait(timeout=120)
      machine.wait_for_shutdown()
      manual_log = machine.full_console_log[manual_log_start:]
      assert any("forgejo-runner-aggregate-lifecycle.service: Deactivated successfully." in line for line in manual_log)
      assert not any("aggregate lifecycle:" in line for line in manual_log)
      assert not any("forgejobuilds.slice: Unit now thawed." in line for line in manual_log)
      assert not any("Cannot stop frozen unit" in line for line in manual_log)

      machine.start()
      machine.wait_for_unit("multi-user.target")
      assert not any("Found ordering cycle" in line for line in machine.full_console_log)
      machine.succeed("systemctl start forgejo-runner-docker.service forgejo-runner-podman.service", timeout=150)
      machine.wait_until_succeeds("systemctl is-active --quiet forgejo-runner-aggregate-lifecycle.service", timeout=60)
      workers()
      machine.succeed(pressure(99, 11))
      machine.wait_until_succeeds("test $(systemctl show forgejobuilds.slice -p FreezerState --value) = frozen")
      machine.succeed("test -e /run/forgejo-runner-aggregate-pressure/owned")
      machine.succeed("touch /run/forgejo-runner-aggregate-pressure/pending")
      ambiguous_log_start = len(machine.full_console_log)
      assert machine.shell is not None
      machine.shell.send(b"poweroff\n")
      assert machine.process is not None
      machine.process.wait(timeout=120)
      machine.wait_for_shutdown()
      ambiguous_log = machine.full_console_log[ambiguous_log_start:]
      assert any("forgejo-runner-aggregate-lifecycle.service: Deactivated successfully." in line for line in ambiguous_log)
      assert not any("aggregate lifecycle:" in line for line in ambiguous_log)
      assert not any("forgejobuilds.slice: Unit now thawed." in line for line in ambiguous_log)
      assert not any("Cannot stop frozen unit" in line for line in ambiguous_log)
    '';
  }
