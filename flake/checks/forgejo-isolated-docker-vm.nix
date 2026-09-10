# Disposable qualification only; deliberately excluded from ordinary flake checks.
{pkgs}: let
  anonymousMemoryHog = pkgs.pkgsStatic.stdenv.mkDerivation {
    pname = "anonymous-memory-hog";
    version = "1";
    dontUnpack = true;
    source = pkgs.writeText "anonymous-memory-hog.c" ''
      #include <errno.h>
      #include <stdio.h>
      #include <stdlib.h>
      #include <sys/mman.h>
      #include <unistd.h>

      static void allocate_and_hold(void) {
        const size_t bytes = (size_t)1024 * 1024 * 1024;
        const long page_size = sysconf(_SC_PAGESIZE);
        volatile unsigned char *memory;
        FILE *oom_score;

        if (page_size <= 0) _exit(2);
        oom_score = fopen("/proc/self/oom_score_adj", "w");
        if (oom_score != NULL) {
          fputs("1000\n", oom_score);
          fclose(oom_score);
        }
        memory = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (memory == MAP_FAILED) _exit(errno == ENOMEM ? 3 : 4);
        for (size_t offset = 0; offset < bytes; offset += (size_t)page_size)
          memory[offset] = (unsigned char)(offset / (size_t)page_size);
        for (;;) pause();
      }

      int main(void) {
        const pid_t child = fork();
        if (child < 0) return 5;
        if (child == 0) allocate_and_hold();
        for (;;) pause();
      }
    '';
    buildPhase = ''
      $CC -static -O2 -Wall -Wextra -Werror -o anonymous-memory-hog $source
    '';
    installPhase = ''
      install -Dm755 anonymous-memory-hog $out/bin/anonymous-memory-hog
    '';
  };
  fixture = pkgs.dockerTools.buildLayeredImage {
    name = "runner-fixture";
    tag = "local";
    contents = [pkgs.pkgsStatic.busybox anonymousMemoryHog];
    config.Cmd = ["/bin/sleep" "600"];
  };
in
  pkgs.testers.runNixOSTest {
    name = "forgejo-rootless-daemon-qualification";
    nodes.machine = {lib, ...}: {
      imports = [../../modules/nixos/services/forgejo-actions-runner];
      options.sops.secrets = lib.mkOption {
        type = lib.types.attrs;
        default = {};
      };
      config = {
        system.stateVersion = "25.11";
        # NixOS tests default to panicking on any OOM. Exercise normal memcg
        # victim selection so the daemon's survival can be verified.
        boot.kernel.sysctl."vm.panic_on_oom" = 0;
        virtualisation = {
          memorySize = 1536;
          cores = 2;
          diskSize = 4096;
          docker.enable = true;
        };
        services.forgejo-actions-runner = {
          enable = true;
          labels = ["fixture:docker://example.invalid/unused:local"];
          secretsFile = pkgs.writeText "unused-dummy-secrets" "dummy";
          isolatedDocker.enable = true;
        };
        # Never register or connect to Forgejo. Test only the generic daemon.
        systemd.services.forgejo-actions-runner.wantedBy = lib.mkForce [];
        systemd.services.forgejo-runner-io-pressure-guard.environment = {
          PRESSURE_FILE = "/run/fixture-pressure";
          SAMPLE_SECONDS = lib.mkForce "1";
          HIGH_SAMPLES_REQUIRED = lib.mkForce "2";
          LOW_SAMPLES_REQUIRED = lib.mkForce "2";
        };
        environment.systemPackages = [pkgs.docker pkgs.procps];
      };
    };
    testScript = ''
      start_all()
      machine.wait_for_unit("multi-user.target")
      machine.succeed("test $(sysctl -n vm.panic_on_oom) = 0")
      machine.succeed("printf 'full avg10=0.00 avg60=0.00 avg300=0.00 total=0\\n' > /run/fixture-pressure")
      machine.succeed("systemctl start forgejo-runner-docker.service", timeout=150)
      machine.wait_for_unit("forgejo-runner-docker.service")
      machine.succeed("test $(systemctl show forgejo-runner-docker.service -p OOMPolicy --value) = continue")
      machine.succeed("systemctl is-active forgejo-runner-io-pressure-guard.service")
      docker = "docker -H unix:///run/forgejo-docker/docker.sock"
      machine.succeed(f"{docker} info")
      machine.succeed(f"su -s /bin/sh forgejo-runner -c '{docker} version'")
      machine.succeed(f"{docker} load < ${fixture}")
      machine.succeed(f"{docker} run -d --name fixture runner-fixture:local")
      pid = machine.succeed(f"{docker} inspect --format '{{{{.State.Pid}}}}' fixture").strip()
      assert "forgejobuilds.slice/forgejo-runner-docker.service" in machine.succeed(f"cat /proc/{pid}/cgroup")

      # Docker accepts the override because this rootless daemon has no
      # per-container cgroup delegation. Its worker must still remain below the
      # daemon service and the aggregate slice.
      machine.succeed(f"{docker} run -d --name override --cgroup-parent=/ runner-fixture:local")
      override_pid = machine.succeed(f"{docker} inspect --format '{{{{.State.Pid}}}}' override").strip()
      assert "forgejobuilds.slice/forgejo-runner-docker.service" in machine.succeed(f"cat /proc/{override_pid}/cgroup")

      # On this two-vCPU VM, the configured 50% aggregate ceiling is one CPU.
      cpu_max = machine.succeed("cat /sys/fs/cgroup/forgejobuilds.slice/cpu.max").split()
      assert cpu_max == ["100000", "100000"]
      for name in ["cpu-hog-1", "cpu-hog-2"]:
          machine.succeed(f"{docker} run -d --name {name} runner-fixture:local /bin/sh -c 'while :; do :; done'")
      machine.succeed("sleep 1")
      cpu_before = int(machine.succeed("awk '/^usage_usec/ { print $2 }' /sys/fs/cgroup/forgejobuilds.slice/cpu.stat"))
      machine.succeed("sleep 5")
      cpu_after = int(machine.succeed("awk '/^usage_usec/ { print $2 }' /sys/fs/cgroup/forgejobuilds.slice/cpu.stat"))
      assert 3000000 <= cpu_after - cpu_before <= 6500000
      machine.succeed(f"{docker} rm --force cpu-hog-1 cpu-hog-2")

      # Touch and retain 1 GiB of anonymous memory below a roughly 768 MiB
      # aggregate maximum. First prove the default 40% soft throttle, then
      # temporarily raise only the fixture's soft threshold to the unchanged
      # hard maximum so the cgroup OOM path can be exercised promptly.
      memory_max = int(machine.succeed("cat /sys/fs/cgroup/forgejobuilds.slice/memory.max"))
      assert 700 * 1024 * 1024 <= memory_max <= 800 * 1024 * 1024
      memory_high = int(machine.succeed("cat /sys/fs/cgroup/forgejobuilds.slice/memory.high"))
      assert 550 * 1024 * 1024 <= memory_high <= 650 * 1024 * 1024
      memory_events_before = {
          key: int(value)
          for key, value in (
              line.split()
              for line in machine.succeed("cat /sys/fs/cgroup/forgejobuilds.slice/memory.events").splitlines()
          )
      }
      machine.succeed(f"{docker} run -d --name memory-hog runner-fixture:local /bin/anonymous-memory-hog")
      machine.wait_until_succeeds(
          "test $(awk '/^high / { print $2 }' /sys/fs/cgroup/forgejobuilds.slice/memory.events) -gt "
          + str(memory_events_before["high"]),
          timeout=30,
      )
      machine.succeed(f"printf '%s\\n' {memory_max} > /sys/fs/cgroup/forgejobuilds.slice/memory.high")
      machine.wait_until_succeeds(
          "test $(awk '/^oom_kill / { print $2 }' /sys/fs/cgroup/forgejobuilds.slice/memory.events) -gt "
          + str(memory_events_before["oom_kill"]),
          timeout=30,
      )
      memory_events_after = {
          key: int(value)
          for key, value in (
              line.split()
              for line in machine.succeed("cat /sys/fs/cgroup/forgejobuilds.slice/memory.events").splitlines()
          )
      }
      assert memory_events_after["max"] > memory_events_before["max"]
      assert memory_events_after["high"] > memory_events_before["high"]
      assert memory_events_after["oom"] > memory_events_before["oom"]
      assert memory_events_after["oom_kill"] > memory_events_before["oom_kill"]
      memory_current = int(machine.succeed("cat /sys/fs/cgroup/forgejobuilds.slice/memory.current"))
      memory_peak = int(machine.succeed("cat /sys/fs/cgroup/forgejobuilds.slice/memory.peak"))
      assert memory_current <= memory_max
      # Per-CPU charge batching can briefly overshoot memory.max before the
      # memcg OOM path runs. Keep that overshoot small and far below host RAM.
      assert memory_peak <= memory_max + 16 * 1024 * 1024
      machine.succeed(f"test $({docker} inspect --format '{{{{.State.Running}}}}' memory-hog) = true")
      machine.succeed("systemctl is-active forgejo-runner-docker.service")
      machine.succeed(f"{docker} rm --force memory-hog")
      machine.succeed(f"printf '%s\\n' {memory_high} > /sys/fs/cgroup/forgejobuilds.slice/memory.high")

      machine.succeed("mkdir /run/build-fixture; printf 'FROM runner-fixture:local\\nRUN sleep 30\\n' > /run/build-fixture/Dockerfile")
      machine.succeed(f"{docker} build /run/build-fixture > /run/build-output 2>&1 &")
      machine.wait_until_succeeds("pgrep -f '^sleep 30$'")
      build_pid = machine.succeed("pgrep -f '^sleep 30$'").strip()
      assert "forgejobuilds.slice/forgejo-runner-docker.service" in machine.succeed(f"cat /proc/{build_pid}/cgroup")
      machine.succeed("printf 'full avg10=99.00 avg60=99.00 avg300=99.00 total=1\\n' > /run/fixture-pressure")
      machine.wait_until_succeeds("test $(systemctl show forgejobuilds.slice -p FreezerState --value) = frozen")
      machine.succeed("systemctl is-active docker.service")
      machine.succeed("docker info > /dev/null", timeout=10)
      machine.succeed("printf 'full avg10=0.00 avg60=0.00 avg300=0.00 total=1\\n' > /run/fixture-pressure")
      machine.wait_until_succeeds("test $(systemctl show forgejobuilds.slice -p FreezerState --value) = running")
      machine.succeed("systemctl kill --signal=KILL --kill-whom=all forgejo-runner-io-pressure-guard.service")
      machine.wait_until_succeeds("test $(systemctl show forgejo-runner-docker.service -p ActiveState --value) = inactive", timeout=120)
      machine.fail(f"test -e /proc/{pid}")
      machine.fail(f"test -e /proc/{build_pid}")
      machine.succeed("systemctl is-active docker.service")
    '';
  }
