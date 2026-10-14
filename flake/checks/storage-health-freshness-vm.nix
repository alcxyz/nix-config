# Disposable qualification of durable success and real systemd timer evidence.
{pkgs}: let
  monitor = ../../modules/nixos/services/storage-health-monitor;
  fixtures = ["freshness" "calendar" "bootcap"];
  pendingTimer = pkgs.writeShellScript "fixture-pending-first-timer" ''
    exec ${pkgs.python3}/bin/python3 ${monitor}/check-pending-first-timer.py "$@"
  '';
  checker = pkgs.writeShellApplication {
    name = "fixture-check-freshness";
    runtimeInputs = [pkgs.coreutils pkgs.gawk pkgs.systemd];
    text = ''
      export STORAGE_HEALTH_PENDING_TIMER=${pendingTimer}
      exec ${pkgs.bash}/bin/bash ${monitor}/check-recent-success.sh "$@"
    '';
  };
in
  if pkgs.stdenv.hostPlatform.system != "x86_64-linux"
  then pkgs.runCommand "storage-health-freshness-unsupported-platform" {} ''touch "$out"''
  else
    pkgs.testers.runNixOSTest {
      name = "storage-health-freshness";
      nodes.machine = {lib, ...}: {
        imports = [monitor];
        system.stateVersion = "25.11";
        virtualisation.memorySize = 1024;
        environment.systemPackages = [checker pkgs.python3];
        services.storage-health-monitor = {
          enable = true;
          pingBaseFile = "/run/fixture-unused-ping";
          units =
            map (name: {
              name = "${name}.service";
              mode = "recent-success";
              maximumAgeSeconds = 120;
              allowPendingFirstTimer = true;
            })
            fixtures;
        };
        # Only invoke the checker: this test must never send a health ping.
        systemd.timers.storage-health-monitor.wantedBy = lib.mkForce [];
        systemd.services = lib.genAttrs fixtures (name: {
          serviceConfig = {
            Type = "oneshot";
            User = "root";
            TimeoutStartSec = "90s";
          };
          unitConfig.StartLimitIntervalSec = 0;
          script = ''
            touch /run/${name}-entered
            while test -e /run/${name}-block; do sleep 0.05; done
            test ! -e /run/${name}-fail
          '';
        });
      };
      testScript = ''
        import hashlib
        import json
        import shlex

        def marker(name):
            digest = hashlib.sha256((name + ".service").encode()).hexdigest()
            return "/var/lib/storage-health-monitor/success/" + digest

        def check(name="freshness", maximum=120, pending=True, cap=3600):
            args = [name + ".service", str(maximum), str(pending).lower(), marker(name), "/proc/uptime"]
            if cap is not None:
                args.append(str(cap))
            return "fixture-check-freshness " + shlex.join(args)

        def property(name, kind, prop):
            # get-property JSON preserves uint64 microseconds, unlike the
            # human-readable timestamps emitted by systemctl show.
            path = "/org/freedesktop/systemd1/unit/" + name + "_2e" + kind
            reply = machine.succeed(
                "busctl --system --json=short get-property org.freedesktop.systemd1 "
                + path + " org.freedesktop.systemd1." + kind.title() + " " + prop
            )
            return json.loads(reply)["data"]

        def install_timer(name, settings):
            # Runtime units have real [Install] metadata so disable/enable can
            # be exercised without changing declarative /etc symlinks.
            unit = "[Unit]\nDescription=Disposable freshness fixture\n[Timer]\nUnit=" + name + ".service\n" + settings
            unit += "\n[Install]\nWantedBy=timers.target\n"
            machine.succeed("printf %s " + shlex.quote(unit) + " > /run/systemd/system/" + name + ".timer")
            machine.succeed("systemctl daemon-reload")

        def guest_clock(clock):
            return float(machine.succeed(
                "python3 -c " + shlex.quote("import time; print(time.clock_gettime(time." + clock + "))")
            ).strip())

        start_all()
        machine.wait_for_unit("multi-user.target")
        machine.succeed("systemctl start freshness.service")
        machine.succeed(check(pending=False))
        machine.succeed("test -s " + marker("freshness"))
        machine.succeed("date -d '1 hour ago' +%s > " + marker("freshness"))
        old = machine.succeed("cat " + marker("freshness"))
        boot_id = machine.succeed("cat /proc/sys/kernel/random/boot_id")
        machine.reboot()
        machine.wait_for_shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        assert machine.succeed("cat /proc/sys/kernel/random/boot_id") != boot_id
        assert machine.succeed("cat " + marker("freshness")) == old
        assert machine.succeed("systemctl show freshness.service -p ExecMainStartTimestampMonotonic --value").strip() == "0"

        with subtest("durable freshness and an inactive timer after reboot"):
            machine.fail(check())
            # A fresh marker needs no pending-timer exception or active timer.
            machine.succeed("date +%s > " + marker("freshness"))
            machine.succeed(check(pending=False))
            machine.succeed("printf %s " + shlex.quote(old) + " > " + marker("freshness"))
            install_timer("freshness", "OnActiveSec=60s\nAccuracySec=1us\n")
            machine.fail(check())
            machine.succeed("touch /run/freshness-block")
            machine.succeed("systemctl enable --runtime --now freshness.timer")
            machine.succeed(check())
            machine.fail(check(pending=False))
            machine.succeed("systemctl disable --runtime --now freshness.timer")
            machine.fail("systemctl is-enabled --quiet freshness.timer")
            machine.fail(check())

        with subtest("actual randomized schedule, stale and missing success"):
            install_timer("freshness", "OnActiveSec=15s\nRandomizedDelaySec=5s\nAccuracySec=1us\n")
            before = guest_clock("CLOCK_MONOTONIC")
            machine.succeed("systemctl start freshness.timer")
            after = guest_clock("CLOCK_MONOTONIC")
            deadline = property("freshness", "timer", "NextElapseUSecMonotonic") / 1000000
            assert property("freshness", "timer", "RandomizedDelayUSec") == 5000000
            assert property("freshness", "timer", "AccuracyUSec") == 1
            # A real randomized delay is included in the numeric next deadline.
            # Activation lies within these guest-clock observations.
            assert before + 15 < deadline <= after + 20
            machine.succeed(check())
            machine.fail(check(pending=False))
            machine.succeed("mv " + marker("freshness") + " /run/stale-success")
            machine.succeed(check())
            machine.fail(check(pending=False))
            assert machine.succeed("systemctl show freshness.service -p ExecMainStartTimestampMonotonic --value").strip() == "0"

        with subtest("first trigger ends grace before the blocked run completes"):
            machine.wait_until_succeeds("test -e /run/freshness-entered", timeout=30)
            assert machine.succeed("systemctl show freshness.service -p ActiveState --value").strip() == "activating"
            assert property("freshness", "timer", "LastTriggerUSecMonotonic") > 0
            machine.fail(check())
            machine.succeed("mv /run/stale-success " + marker("freshness"))
            machine.fail(check())
            machine.succeed("rm /run/freshness-block")
            machine.wait_until_succeeds("test $(systemctl show freshness.service -p ActiveState --value) = inactive", timeout=10)
            machine.succeed(check(pending=False))
            assert machine.succeed("cat " + marker("freshness")) != old
            success = machine.succeed("cat " + marker("freshness"))
            machine.succeed("printf %s " + shlex.quote(old) + " > " + marker("freshness"))
            machine.fail(check())
            machine.succeed("printf %s " + shlex.quote(success) + " > " + marker("freshness"))
            machine.succeed("systemctl stop freshness.timer")

        with subtest("a current failed result overrides fresh durable success"):
            success = machine.succeed("cat " + marker("freshness"))
            machine.succeed("touch /run/freshness-fail")
            machine.fail("systemctl start freshness.service")
            assert machine.succeed("systemctl show freshness.service -p Result --value").strip() == "exit-code"
            assert machine.succeed("cat " + marker("freshness")) == success
            machine.fail(check())
            machine.succeed("rm /run/freshness-fail; systemctl start freshness.service")
            machine.succeed(check())

        with subtest("calendar first deadline uses realtime numeric evidence"):
            calendar = machine.succeed("date -u -d '+30 seconds' '+%Y-%m-%d %H:%M:%S UTC'").strip()
            install_timer("calendar", "OnCalendar=" + calendar + "\nAccuracySec=1us\n")
            machine.succeed("systemctl start calendar.timer")
            assert property("calendar", "timer", "NextElapseUSecRealtime") > 0
            assert property("calendar", "timer", "NextElapseUSecMonotonic") == 0
            machine.succeed(check("calendar"))
            machine.fail(check("calendar", pending=False))
            machine.succeed("systemctl stop calendar.timer")

        with subtest("boot cap expires and restarting cannot extend it"):
            install_timer("bootcap", "OnActiveSec=60s\nAccuracySec=1us\n")
            machine.succeed("systemctl start bootcap.timer")
            # Derive a short future cap from measured CLOCK_BOOTTIME rather
            # than assuming how quickly this VM reached multi-user.target.
            cap = int(guest_clock("CLOCK_BOOTTIME")) + 10
            machine.succeed(check("bootcap", cap=cap))
            machine.succeed(check("bootcap", maximum=cap, cap=None))
            wait = "import time; time.sleep(max(0, " + str(cap) + " - time.clock_gettime(time.CLOCK_BOOTTIME)) + 0.1)"
            machine.succeed("python3 -c " + shlex.quote(wait), timeout=15)
            machine.fail(check("bootcap", cap=cap))
            machine.fail(check("bootcap", maximum=cap, cap=None))
            previous = property("bootcap", "timer", "NextElapseUSecMonotonic")
            machine.succeed("systemctl restart bootcap.timer")
            assert property("bootcap", "timer", "NextElapseUSecMonotonic") > previous
            assert property("bootcap", "timer", "LastTriggerUSecMonotonic") == 0
            assert machine.succeed("systemctl show bootcap.service -p ExecMainStartTimestampMonotonic --value").strip() == "0"
            machine.fail(check("bootcap", cap=cap))
            machine.fail(check("bootcap", maximum=cap, cap=None))
            machine.succeed("systemctl stop bootcap.timer")

        machine.fail("systemctl is-active --quiet storage-health-monitor.service")
        machine.fail("systemctl is-active --quiet storage-health-monitor.timer")
      '';
    }
