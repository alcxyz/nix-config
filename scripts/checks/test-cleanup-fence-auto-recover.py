#!/usr/bin/env python3
"""Automatic fence recovery: when it stops the APIs and hands over to the proof.

The recovery proof itself is covered by test-cleanup-fence-recovery.py, and the
real lifecycle by the cleanup fence VM test.
"""

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(sys.argv.pop(1)).resolve() / "cleanup-fence-auto-recover.sh"
RUNNERS = [
    "forgejo-actions-runner.service",
    "forgejo-podman-runner.service",
    "forgejo-podman-runner-fast.service",
]
APIS = ["forgejo-runner-docker.service", "forgejo-runner-podman.service"]
PRUNES = [
    "forgejo-runner-cache-prune.service",
    "forgejo-runner-cache-pressure-prune.service",
]
MARKERS = [
    "owned",
    "pending",
    "teardown-required",
    "drain-pending",
    "resume-pending",
    "drain-disowned",
]
OWNER = (
    "cleanup-v2 123 123 0 DELETE /v5.0.0/libpod/containers/" + "a" * 64 + "?force=false"
)


class AutoRecoverTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        for unit in RUNNERS[1:]:
            (self.state / "runners" / unit).mkdir(parents=True)
        self.state.chmod(0o700)
        self.fence = self.state / "cleanup-in-flight"
        self.calls = self.root / "calls"
        self.calls.write_text("")
        self.units = {
            unit: {
                "ActiveState": "inactive",
                "SubState": "dead",
                "MainPID": "0",
                "ControlPID": "0",
                "Job": "",
            }
            for unit in RUNNERS
        }
        self.units["forgejobuilds.slice"] = {"FreezerState": "running"}
        for unit in PRUNES:
            self.units[unit] = {"ActiveState": "inactive", "Job": ""}
        self.save_units()
        systemctl = self.root / "systemctl"
        systemctl.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
args = sys.argv[1:]
if args[0] in ('stop', 'start'):
    with open(root / 'calls', 'a') as calls:
        calls.write(' '.join(args) + '\\n')
    sys.exit(1 if (root / ('fail-' + args[0])).exists() else 0)
if args[0] == 'is-active':
    down = 'guard-inactive' if args[-1].endswith('-guard.service') else 'api-down'
    sys.exit(1 if (root / down).exists() else 0)
assert args[0] == 'show', args
data = json.loads((root / 'units').read_text())[args[-1]]
for argument in args[1:-1]:
    if argument.startswith('--property='):
        key = argument.split('=', 1)[1]
        print(data[key] if '--value' in args else key + '=' + data[key])
""")
        systemctl.chmod(0o755)
        # The real recovery clears the fence only after its proof succeeds.
        recover = self.root / "recover"
        recover.write_text(f"""#!/usr/bin/env bash
echo recover >> {self.calls}
[[ ! -e {self.root}/refuse ]] || {{ echo 'cleanup fence recovery refused: fixture' >&2; exit 1; }}
rm -r -- {self.fence}
""")
        recover.chmod(0o755)
        self.env = {
            **os.environ,
            "FIXTURE_ROOT": str(self.root),
            "STATE_DIR": str(self.state),
            "SYSTEMCTL_BIN": str(systemctl),
            "RECOVER_BIN": str(recover),
            "RUNNER_UNITS": " ".join(RUNNERS),
            "SETTLE_SECONDS": "300",
        }

    def save_units(self):
        (self.root / "units").write_text(json.dumps(self.units))

    def make_fence(self, owner=OWNER, age=600):
        self.fence.mkdir(mode=0o700)
        for name, text in [
            ("owner", owner + "\n"),
            ("api-generations", "".join(f"{api} 12345\n" for api in APIS)),
            ("response", ""),
        ]:
            path = self.fence / name
            path.write_text(text)
            path.chmod(0o600)
        self.age(age)

    def age(self, seconds, *names):
        stamp = time.time() - seconds
        for path in [self.fence / name for name in names] or [
            self.fence,
            *self.fence.iterdir(),
        ]:
            os.utime(path, (stamp, stamp), follow_symlinks=False)

    def run_script(self):
        return subprocess.run(
            ["bash", str(SCRIPT)],
            env=self.env,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def calls_made(self):
        return self.calls.read_text().splitlines()

    def assert_skipped(self, reason):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(
            result.stdout.startswith("skipped reason=" + reason), result.stdout
        )
        self.assertEqual(self.calls_made(), [])
        return result

    def assert_failed(self, step):
        result = self.run_script()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("failed step=" + step, result.stderr)
        return result

    def test_settled_fence_stops_apis_recovers_then_starts_them(self):
        self.make_fence()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.calls_made(),
            ["stop " + " ".join(APIS), "recover", "start " + " ".join(APIS)],
        )
        self.assertIn("recovered owner=" + OWNER, result.stdout)
        self.assertFalse(self.fence.exists())

    def test_failed_runners_count_as_terminal(self):
        self.units[RUNNERS[2]].update(ActiveState="failed", SubState="failed")
        self.save_units()
        self.make_fence()
        self.assertEqual(self.run_script().returncode, 0)
        self.assertFalse(self.fence.exists())

    def test_no_fence_does_nothing(self):
        self.assert_skipped("no_fence")

    def test_recent_fence_or_late_response_waits(self):
        self.make_fence(age=10)
        self.assert_skipped("settling")
        self.age(600)
        # A response that arrives after the client gave up changes the fence.
        self.age(10, "response")
        self.assert_skipped("settling")
        self.env["SETTLE_SECONDS"] = "5"
        self.assertEqual(self.run_script().returncode, 0)

    def test_refused_recovery_leaves_fence_and_apis_stopped(self):
        self.make_fence()
        (self.root / "refuse").touch()
        self.assert_failed("recovery_refused")
        self.assertEqual(self.calls_made(), ["stop " + " ".join(APIS), "recover"])
        self.assertTrue((self.fence / "owner").exists())

    def test_failed_stop_never_runs_recovery(self):
        self.make_fence()
        (self.root / "fail-stop").touch()
        self.assert_failed("api_stop")
        self.assertEqual(self.calls_made(), ["stop " + " ".join(APIS)])
        self.assertTrue(self.fence.exists())

    def test_failed_start_is_reported(self):
        self.make_fence()
        (self.root / "fail-start").touch()
        self.assert_failed("api_start")
        self.assertFalse(self.fence.exists())

    def test_start_skipped_by_its_condition_is_reported(self):
        self.make_fence()
        (self.root / "api-down").touch()
        self.assert_failed("api_start unit=" + APIS[0])
        self.assertEqual(self.calls_made()[-1], "start " + " ".join(APIS))

    def test_running_cache_prune_keeps_apis_running(self):
        self.make_fence()
        for unit in PRUNES:
            for key, value in [("ActiveState", "activating"), ("Job", "9")]:
                with self.subTest(unit=unit, key=key):
                    original = self.units[unit][key]
                    self.units[unit][key] = value
                    self.save_units()
                    self.assert_skipped("prune_active unit=" + unit)
                    self.units[unit][key] = original
                    self.save_units()
        self.assertEqual(self.run_script().returncode, 0)

    def test_manual_docker_volume_fence_stays_manual(self):
        self.make_fence(
            owner="cleanup-v3 123 123 0 docker DELETE /volumes/fixture?force=false"
        )
        self.assert_skipped("manual_docker_fence")
        self.assertTrue(self.fence.exists())

    def test_active_or_pending_runner_keeps_apis_running(self):
        self.make_fence()
        for unit in RUNNERS:
            for key, value in [
                ("ActiveState", "active"),
                ("ActiveState", "deactivating"),
                ("SubState", "running"),
                ("MainPID", "42"),
                ("ControlPID", "42"),
                ("Job", "17"),
            ]:
                with self.subTest(unit=unit, key=key, value=value):
                    original = self.units[unit][key]
                    self.units[unit][key] = value
                    self.save_units()
                    self.assert_skipped("runner_active unit=" + unit)
                    self.units[unit][key] = original
                    self.save_units()

    def test_transition_markers_keep_apis_running(self):
        self.make_fence()
        for directory in [self.state] + [
            self.state / "runners" / unit for unit in RUNNERS[1:]
        ]:
            for marker in MARKERS:
                with self.subTest(directory=directory.name, marker=marker):
                    (directory / marker).touch()
                    self.assert_skipped("transition_marker marker=" + marker)
                    (directory / marker).unlink()

    def test_frozen_aggregate_or_inactive_guard_keeps_apis_running(self):
        self.make_fence()
        self.units["forgejobuilds.slice"]["FreezerState"] = "frozen"
        self.save_units()
        self.assert_skipped("aggregate_frozen")
        self.units["forgejobuilds.slice"]["FreezerState"] = "running"
        self.save_units()
        (self.root / "guard-inactive").touch()
        self.assert_skipped("guard_inactive")

    def test_untrusted_or_malformed_fences_fail_without_stopping(self):
        self.make_fence(owner="cleanup-v1 garbage")
        self.assert_failed("fence_format")
        (self.fence / "owner").unlink()
        self.assert_failed("fence_untrusted")
        (self.fence / "owner").symlink_to(self.root / "units")
        self.assert_failed("fence_untrusted")
        (self.fence / "owner").unlink()
        (self.fence / "owner").write_text(OWNER + "\n")
        (self.fence / "extra").symlink_to(self.root / "units")
        self.age(600, "owner")
        self.assert_failed("fence_untrusted")
        self.assertEqual(self.calls_made(), [])

    def test_symlinked_fence_or_state_fails(self):
        target = self.root / "elsewhere"
        target.mkdir(mode=0o700)
        self.fence.symlink_to(target)
        self.assert_failed("fence_untrusted")
        self.fence.unlink()
        self.make_fence()
        self.state.chmod(0o755)
        self.assert_failed("state_directory")
        self.assertEqual(self.calls_made(), [])

    def test_invalid_runner_list_exits(self):
        self.make_fence()
        for runners in ["", RUNNERS[0], " ".join(reversed(RUNNERS)), "bad name.service x"]:
            with self.subTest(runners=runners):
                self.env["RUNNER_UNITS"] = runners
                self.assertEqual(self.run_script().returncode, 1)
        self.assertEqual(self.calls_made(), [])


if __name__ == "__main__":
    unittest.main()
