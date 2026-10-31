# Offline Podman store reset with both production API units (ADR-0105).
{pkgs}:
if pkgs.stdenv.hostPlatform.system != "x86_64-linux"
then pkgs.runCommand "forgejo-podman-store-reset-unsupported-platform" {} ''touch "$out"''
else let
  # A real image, container and volume in the store that a reset discards.
  fixtureImage = pkgs.dockerTools.buildLayeredImage {
    name = "store-reset-fixture";
    tag = "local";
    contents = [pkgs.pkgsStatic.busybox];
    config.Cmd = ["/bin/busybox" "true"];
  };
  quietPressure = pkgs.writeText "fixture-quiet-pressure" "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n";
  reset = "forgejo-podman-store-reset.service";
  successMarker = "/var/lib/storage-health-monitor/success/${builtins.hashString "sha256" reset}";
in
  pkgs.testers.runNixOSTest {
    name = "forgejo-podman-store-reset";
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
          name = "reset-fixture";
          labels = ["fixture:docker://example.invalid/unused:local"];
          secretsFile = pkgs.writeText "fixture-secrets" "unused";
          isolatedDocker.enable = true;
          runnerHold.diskSpace = {
            enable = true;
            drainFreeGiB = 2;
            recoveryFreeGiB = 3;
            drainFreePercent = 2;
            recoveryFreePercent = 3;
          };
          podmanStoreReset.enable = true;
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
        systemd.timers.forgejo-podman-store-reset.wantedBy = lib.mkForce [];
        systemd.services.forgejo-podman-store-reset = {
          unitConfig.StartLimitIntervalSec = 0;
          # The VM's own I/O stall must not decide whether the reset runs.
          environment.PRESSURE_FILE = toString quietPressure;
        };
        # Repeated lifecycle trials run faster than the normal start-limit
        # interval. Qualify the reset itself without this fixture exhausting it.
        systemd.sockets.forgejo-runner-podman.unitConfig.StartLimitIntervalSec = 0;
        systemd.services.forgejo-runner-docker.unitConfig.StartLimitIntervalSec = 0;
        systemd.services.forgejo-runner-podman.unitConfig.StartLimitIntervalSec = 0;
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
          (pkgs.writeShellApplication {
            name = "fixture-reset-health";
            runtimeInputs = [pkgs.coreutils pkgs.gawk pkgs.systemd];
            text = ''
              export STORAGE_HEALTH_PENDING_TIMER=${pkgs.writeShellScript "fixture-pending-timer" ''
                exec ${pkgs.python3}/bin/python3 ${../../modules/nixos/services/storage-health-monitor/check-pending-first-timer.py} "$@"
              ''}
              exec bash ${../../modules/nixos/services/storage-health-monitor/check-recent-success.sh} ${reset} 10800 true ${successMarker} /proc/uptime 1320
            '';
          })
          # Pauses the reset at a chosen systemd call (`on`), or at the call
          # after it (`after`), so the test can act while the reset holds the
          # start lock or right after the rename.
          (pkgs.writeShellApplication {
            name = "fixture-reset-systemctl";
            runtimeInputs = [pkgs.coreutils pkgs.systemd];
            text = ''
              pause() {
                touch /run/reset-entered
                while [[ -e /run/reset-pause ]]; do sleep 0.05; done
              }
              if [[ -e /run/reset-pause ]]; then
                read -r mode command < /run/reset-pause
                if [[ -e /run/reset-armed ]]; then
                  pause
                elif [[ "$*" == "$command" ]]; then
                  if [[ $mode == on ]]; then pause; else touch /run/reset-armed; fi
                fi
              fi
              exec systemctl "$@"
            '';
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
    testScript = {nodes, ...}: ''
      import re
      import shlex
      state = "/run/forgejo-runner-hold"
      legacy_state = "/run/forgejo-runner-aggregate-pressure"
      runners = ${builtins.toJSON nodes.machine.services.forgejo-actions-runner.runnerUnits}
      assert runners == ["forgejo-actions-runner.service", "forgejo-podman-runner.service"]
      apis = ["forgejo-runner-docker.service", "forgejo-runner-podman.service"]
      units = apis + runners
      reset = "${reset}"
      store = "${nodes.machine.services.forgejo-actions-runner.podmanCanary.storageRoot}"
      parent = store.rsplit("/", 1)[0]
      stamp = "/var/lib/forgejo-podman-store-reset/reset-at"
      restart_list = "/run/forgejo-podman-store-reset/restart"
      podman = "docker -H unix:///run/forgejo-podman/podman.sock"
      dropin = "/run/systemd/system/forgejo-podman-store-reset.service.d"

      def generation(unit):
          return machine.succeed(f"systemctl show -p ExecMainStartTimestampMonotonic --value {unit}").strip()

      def wait_units():
          for unit in units:
              machine.wait_for_unit(unit)

      def make_due():
          machine.succeed(f"touch -d '-8 days' {stamp}")

      def journal():
          return machine.succeed(f"journalctl -u {reset} -o cat")

      def cursor():
          return len(journal())

      def journal_since(mark):
          return journal()[mark:]

      def populate():
          machine.succeed(f"{podman} load < ${fixtureImage}")
          machine.succeed(f"{podman} create --network none --name reset-fixture store-reset-fixture:local")
          machine.succeed(f"{podman} volume create reset-fixture-volume")
          assert machine.succeed(f"{podman} images -q").strip() != ""

      def store_empty():
          assert machine.succeed(f"{podman} images -q").strip() == ""
          assert machine.succeed(f"{podman} ps -aq").strip() == ""
          assert "reset-fixture-volume" not in machine.succeed(f"{podman} volume ls -q")

      def store_intact():
          assert machine.succeed(f"{podman} images -q").strip() != ""
          assert "reset-fixture-volume" in machine.succeed(f"{podman} volume ls -q")

      def pause(mode, command):
          machine.succeed("rm -f /run/reset-armed /run/reset-entered")
          machine.succeed(f"printf '%s %s\\n' {mode} {shlex.quote(command)} > /run/reset-pause")
          machine.succeed(f"mkdir -p {dropin}; printf '[Service]\\nEnvironment=SYSTEMCTL_BIN=/run/current-system/sw/bin/fixture-reset-systemctl\\n' > {dropin}/fixture.conf; systemctl daemon-reload")
          machine.succeed(f"systemctl start --no-block {reset}")
          machine.wait_until_succeeds("test -e /run/reset-entered", timeout=60)

      def release():
          machine.succeed("rm -f /run/reset-pause /run/reset-armed")

      def unpause():
          release()
          machine.succeed(f"rm -f {dropin}/fixture.conf; systemctl daemon-reload")

      def wait_inactive(unit):
          machine.wait_until_succeeds(f"case $(systemctl show -p ActiveState --value {unit}) in inactive|failed) ;; *) exit 1 ;; esac", timeout=120)

      start_all()
      machine.wait_for_unit("multi-user.target")
      wait_units()
      # Ordinary Docker-only boot and switch keep their original dependency
      # order and need no Podman unit.
      dockerOnly.wait_for_unit("forgejo-actions-runner.service")
      dockerOnly.succeed(f"test -d {state}/runners/forgejo-actions-runner.service")
      dockerOnly.succeed("systemctl stop forgejo-actions-runner.service forgejo-runner-docker.service", timeout=120)
      dockerOnly.succeed("/run/current-system/specialisation/changed/bin/switch-to-configuration test", timeout=180)
      dockerOnly.wait_for_unit("forgejo-actions-runner.service")
      dockerOnly.wait_for_unit("forgejo-runner-docker.service")
      assert "Found ordering cycle" not in dockerOnly.full_console_log
      assert "Found ordering cycle" not in machine.full_console_log
      machine.succeed("docker -H unix:///run/forgejo-docker/docker.sock info >/dev/null")
      machine.succeed(f"{podman} info >/dev/null")
      # The store directory is inside the state directory's filesystem, not a
      # mount of its own here.
      machine.fail(f"mountpoint -q {store}")

      # The pending first timer is healthy; the first run only starts the age
      # clock and leaves everything running.
      machine.succeed("systemctl start forgejo-podman-store-reset.timer")
      machine.succeed("fixture-reset-health")
      machine.succeed("systemctl stop forgejo-podman-store-reset.timer")
      populate()
      before = {unit: generation(unit) for unit in units}
      machine.succeed(f"systemctl start {reset}")
      machine.succeed("fixture-reset-health")
      assert "skipped reason=not_due" in machine.succeed(f"journalctl -u {reset} -o cat")
      machine.succeed(f"test -f {stamp}")
      assert {unit: generation(unit) for unit in units} == before
      store_intact()

      with subtest("a due reset discards the store and brings everything back"):
          # Garbage to time the deletion: 100,000 files and 1 GiB of data.
          machine.succeed(f"mkdir -p {store}/overlay/fixture && cd {store}/overlay/fixture && for d in $(seq 100); do mkdir $d && (cd $d && touch $(seq 1000)); done && fallocate -l 1G {store}/overlay/fixture/blob")
          make_due()
          mark = cursor()
          machine.succeed(f"systemctl start {reset}", timeout=600)
          log = journal_since(mark)
          machine.log(log)
          assert "reset due=store_age" in log
          deleted = re.search(r"trash_deleted seconds=(\d+)", log)
          assert deleted, log
          print(f"measured trash deletion: {deleted.group(1)} s for 100,000 files and 1 GiB")
          wait_units()
          for unit in units:
              assert generation(unit) != before[unit], unit
          store_empty()
          machine.fail(f"ls -d {parent}/.storage.trash.* 2>/dev/null")
          machine.fail(f"test -e {restart_list}")
          machine.succeed("fixture-reset-health")
          populate()

      with subtest("an API start waits for the lock, and its pending start prevents the rename"):
          make_due()
          pause("after", "stop forgejo-runner-docker.service forgejo-runner-podman.service")
          # The reset now holds the start lock, both APIs are stopped.
          for api in apis:
              machine.succeed(f"test $(systemctl show -p ActiveState --value {api}) = inactive")
          machine.succeed("systemctl start --no-block forgejo-runner-podman.service")
          machine.wait_until_succeeds("test $(systemctl show -p ControlPID --value forgejo-runner-podman.service) != 0", timeout=10)
          machine.sleep(3)
          # Its start gate is still waiting for the lock: no API runs.
          machine.succeed("test $(systemctl show -p ActiveState --value forgejo-runner-podman.service) = activating")
          machine.succeed("test $(systemctl show -p MainPID --value forgejo-runner-podman.service) = 0")
          mark = cursor()
          unpause()
          wait_inactive(reset)
          log = journal_since(mark)
          # The Podman API's start also queued the Docker API it binds to.
          assert "skipped reason=unit_not_stopped unit=forgejo-runner-" in log, log
          assert "restarted units=" in log, log
          wait_units()
          store_intact()

      with subtest("a reset killed while it holds the lock leaves the store and restarts the units"):
          make_due()
          pause("after", "stop forgejo-runner-docker.service forgejo-runner-podman.service")
          # The paused child still holds the inherited lock; systemd kills it
          # with the rest of the unit before ExecStopPost runs.
          machine.succeed(f"systemctl kill --kill-whom=main --signal=KILL {reset}")
          # Let ExecStopPost through the same wrapper.
          release()
          wait_inactive(reset)
          unpause()
          wait_units()
          store_intact()
          machine.fail(f"ls -d {parent}/.storage.trash.* 2>/dev/null")
          machine.fail("fixture-reset-health")

      with subtest("a crash after the rename boots on a fresh store; the next run deletes the trash"):
          make_due()
          pause("on", "start " + " ".join(units))
          machine.succeed(f"ls -d {parent}/.storage.trash.*")
          machine.crash()
          machine.start()
          machine.wait_for_unit("multi-user.target")
          wait_units()
          store_empty()
          machine.succeed(f"ls -d {parent}/.storage.trash.*")
          mark = cursor()
          machine.succeed(f"systemctl start {reset}", timeout=600)
          log = journal_since(mark)
          assert "trash_deleted" in log and "skipped reason=not_due" in log, log
          machine.fail(f"ls -d {parent}/.storage.trash.* 2>/dev/null")
          machine.succeed("fixture-reset-health")
          populate()

      with subtest("a completion fence from before ADR-0105 holds nothing and resets the store"):
          machine.succeed(f"mkdir -p -m 700 {legacy_state}/cleanup-in-flight; echo 'cleanup-v2 1 1 0 DELETE /images/x' > {legacy_state}/cleanup-in-flight/owner")
          machine.succeed("systemctl restart forgejo-podman-runner.service")
          machine.wait_for_unit("forgejo-podman-runner.service")
          mark = cursor()
          machine.succeed(f"systemctl start {reset}", timeout=600)
          assert "reset due=legacy_fence" in journal_since(mark)
          machine.fail(f"test -e {legacy_state}/cleanup-in-flight")
          wait_units()
          store_empty()
    '';
  }
