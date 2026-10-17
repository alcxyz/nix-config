#!/usr/bin/env python3
"""Focused proof/refusal fixtures; real lifecycle qualification lives in the VM."""

import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

MODULE = Path(sys.argv.pop(1)).resolve()
TWO_RUNNERS = ["forgejo-actions-runner.service", "forgejo-podman-runner.service"]
EXTRA = "forgejo-podman-runner-fast.service"
THREE_RUNNERS = TWO_RUNNERS + [EXTRA]
APIS = ["forgejo-runner-docker.service", "forgejo-runner-podman.service"]


class RecoveryFixture:
    runners = TWO_RUNNERS

    def setUp(self):
        RUNNERS = self.runners
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        for unit in RUNNERS[1:]:
            (self.state / "runners" / unit).mkdir(parents=True)
        self.state.chmod(0o700)
        (self.state / "runner-units").write_text("\n".join(RUNNERS) + "\n")
        self.fence = self.state / "cleanup-in-flight"
        self.fence.mkdir(mode=0o700)
        self.owner = self.fence / "owner"
        self.owner.write_text(
            "cleanup-v2 123 123 0 DELETE /v5.0.0/libpod/containers/"
            + "a" * 64
            + "?force=false\n"
        )
        self.owner.chmod(0o600)
        generation = self.fence / "api-generations"
        generation.write_text("\n".join(unit + " 12345" for unit in APIS) + "\n")
        generation.chmod(0o600)
        self.cgroup = self.root / "cgroups" / "forgejobuilds.slice"
        self.cgroup.mkdir(parents=True)
        (self.cgroup / "cgroup.events").write_text("populated 0\nfrozen 0\n")
        self.units = {
            unit: {
                "LoadState": "loaded",
                "ActiveState": "inactive",
                "SubState": "dead",
                "MainPID": "0",
                "ControlPID": "0",
                "Job": "",
                "ControlGroup": "",
                "ExecMainStartTimestampMonotonic": "12345",
            }
            for unit in RUNNERS + APIS
        }
        self.units["forgejobuilds.slice"] = {
            "LoadState": "loaded",
            "ActiveState": "active",
            "ControlGroup": "/forgejobuilds.slice",
            "FreezerState": "running",
            "Job": "",
        }
        self.save_units()
        systemctl = self.root / "systemctl"
        systemctl.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys, time
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
args = sys.argv[1:]
if args[0] == 'is-active':
    sys.exit(0)
assert args[0] == 'show', args
if (root / 'pause').exists() and '--property=LoadState' in args:
    (root / 'checkpoint').touch()
    while (root / 'pause').exists(): time.sleep(.01)
data = json.loads((root / 'units').read_text())[args[-1]]
for argument in args[1:-1]:
    if argument.startswith('--property='):
        key = argument.split('=', 1)[1]
        if key in data: print(data[key] if '--value' in args else key + '=' + data[key])
""")
        systemctl.chmod(0o755)
        self.env = {
            **os.environ,
            "FIXTURE_ROOT": str(self.root),
            "STATE_DIR": str(self.state),
            "CGROUP_ROOT": str(self.root / "cgroups"),
            "SYSTEMCTL_BIN": str(systemctl),
            "RUNNER_UNITS": " ".join(RUNNERS),
            "GAME_ADMISSION_ENABLED": "0",
            "DISK_SPACE_ENABLED": "0",
            "GATE_TIMEOUT_SECONDS": "2",
        }

    def save_units(self):
        (self.root / "units").write_text(json.dumps(self.units))

    def command(self, name, **env):
        return ["bash", str(MODULE / name)], {**self.env, **env}

    def run_script(self, name="cleanup-fence-recover.sh", **env):
        command, environment = self.command(name, **env)
        return subprocess.run(
            command,
            env=environment,
            capture_output=True,
            text=True,
            timeout=8,
            check=False,
        )

    def refused(self, **env):
        result = self.run_script(**env)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue(self.fence.exists() or self.fence.is_symlink())

    def runner_dirs(self):
        return [self.state] + [self.state / "runners" / unit for unit in self.runners[1:]]

    def test_terminal_generation_clear_preserves_drain_ownership_and_admits_every_runner(
        self,
    ):
        for directory in self.runner_dirs():
            (directory / "drain-owned").write_text("fixture-owned\n")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.fence.exists())
        for unit, directory in zip(self.runners, self.runner_dirs()):
            self.assertEqual((directory / "drain-owned").read_text(), "fixture-owned\n")
            # Existing guard is responsible for completing its owned resume.
            (directory / "drain-owned").unlink()
            self.assertEqual(
                self.run_script("runner-start-gate.sh", RUNNER_UNIT=unit).returncode, 0
            )

    def test_each_pending_or_active_runner_refuses(self):
        for unit in self.runners:
            for field, value in [
                ("Job", "42"),
                ("MainPID", "42"),
                ("ActiveState", "activating"),
                ("SubState", "stop"),
            ]:
                with self.subTest(unit=unit, field=field):
                    original = self.units[unit][field]
                    self.units[unit][field] = value
                    self.save_units()
                    self.refused()
                    self.units[unit][field] = original
                    self.save_units()

    def test_registry_and_runner_state_must_match_the_baked_list(self):
        registry = self.state / "runner-units"
        for body in [
            "\n".join(self.runners[:-1]) + "\n",
            "\n".join(self.runners + ["forgejo-podman-runner-old.service"]) + "\n",
            "\n".join(reversed(self.runners)) + "\n",
            "\n".join(self.runners) + "\n\n",
        ]:
            with self.subTest(body=body):
                registry.write_text(body)
                self.refused()
        registry.write_text("\n".join(self.runners) + "\n")
        unknown = self.state / "runners" / "forgejo-podman-runner-old.service"
        unknown.mkdir()
        self.refused()
        unknown.rmdir()
        last = self.state / "runners" / self.runners[-1]
        last.rename(self.root / "moved")
        self.refused()
        last.symlink_to(self.root / "moved")
        self.refused()
        last.unlink()
        (self.root / "moved").rename(last)
        for marker in ["owned", "pending", "teardown-required", "drain-pending",
                       "resume-pending", "drain-disowned"]:
            with self.subTest(marker=marker):
                path = last / marker
                path.touch()
                self.refused()
                self.assertTrue(path.exists())
                path.unlink()
        self.assertEqual(self.run_script().returncode, 0)

    def test_invalid_runner_list_refuses(self):
        for units in [
            "",
            TWO_RUNNERS[0],
            " ".join(reversed(TWO_RUNNERS)),
            " ".join(TWO_RUNNERS + [TWO_RUNNERS[1]]),
            " ".join(TWO_RUNNERS + ["../escape.service"]),
            " ".join(TWO_RUNNERS + ["fast"]),
        ]:
            with self.subTest(units=units):
                self.refused(RUNNER_UNITS=units)


class RecoveryTests(RecoveryFixture, unittest.TestCase):
    def test_every_recorded_request_kind_is_recoverable(self):
        digest = "a" * 64
        for path in [
            "DELETE /v5.0.0/libpod/containers/" + digest + "?force=false",
            "DELETE /v5.0.0/libpod/containers/" + digest + "?force=true&timeout=10",
            "DELETE /v5.0.0/libpod/volumes/buildx_buildkit_fixture0_state",
            "DELETE /images/" + digest + "?force=false&noprune=true",
            # Kept by an older cleanup that still used the bulk prune.
            "POST /v5.0.0/libpod/containers/prune",
        ]:
            with self.subTest(path=path):
                if not self.fence.exists():
                    self.fence.mkdir(mode=0o700)
                    generation = self.fence / "api-generations"
                    generation.write_text(
                        "\n".join(unit + " 12345" for unit in APIS) + "\n"
                    )
                    generation.chmod(0o600)
                self.owner.write_text("cleanup-v2 123 123 0 " + path + "\n")
                self.owner.chmod(0o600)
                result = self.run_script()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(self.fence.exists())

    def test_each_pending_or_active_unit_refuses(self):
        for unit in TWO_RUNNERS + APIS:
            for field, value in [
                ("Job", "42"),
                ("Job", "0"),
                ("MainPID", "42"),
                ("ControlPID", "42"),
                ("ActiveState", "activating"),
                ("ActiveState", "deactivating"),
                ("SubState", "stop"),
                ("LoadState", "not-found"),
                ("ExecMainStartTimestampMonotonic", "unknown"),
            ]:
                with self.subTest(unit=unit, field=field):
                    original = self.units[unit][field]
                    self.units[unit][field] = value
                    self.save_units()
                    self.refused()
                    self.units[unit][field] = original
            self.units[unit].pop("Job")
            self.save_units()
            self.refused()
            self.units[unit]["Job"] = ""

    def test_generation_change_is_never_completion(self):
        for unit in APIS:
            self.units[unit]["ExecMainStartTimestampMonotonic"] = "67890"
            self.save_units()
            self.refused()
            self.units[unit]["ExecMainStartTimestampMonotonic"] = "12345"

    def test_clean_stop_zero_generation_requires_full_worker_terminal_proof(self):
        for unit in APIS:
            self.units[unit]["ExecMainStartTimestampMonotonic"] = "0"
        self.save_units()
        (self.cgroup / "cgroup.events").write_text("populated 1\nfrozen 0\n")
        self.refused()
        (self.cgroup / "cgroup.events").write_text("populated 0\nfrozen 0\n")
        self.units[APIS[0]]["Job"] = "1"
        self.save_units()
        self.refused()
        self.units[APIS[0]]["Job"] = ""
        self.units[APIS[0]]["ActiveState"] = "failed"
        self.units[APIS[0]]["SubState"] = "failed"
        self.save_units()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_aggregate_workers_freezer_jobs_and_unknown_evidence_refuse(self):
        for events in [
            "populated 1\nfrozen 0\n",
            "populated 0\nfrozen 1\n",
            "populated 0\n",
            "populated 0\npopulated 0\nfrozen 0\n",
        ]:
            (self.cgroup / "cgroup.events").write_text(events)
            self.refused()
        (self.cgroup / "cgroup.events").write_text("populated 0\nfrozen 0\n")
        for field, values in [
            ("FreezerState", ["frozen", "freezing", "thawing", "unknown"]),
            ("Job", ["1"]),
            ("ControlGroup", ["/other.slice"]),
        ]:
            original = self.units["forgejobuilds.slice"][field]
            for value in values:
                self.units["forgejobuilds.slice"][field] = value
                self.save_units()
                self.refused()
            self.units["forgejobuilds.slice"][field] = original

    def test_active_runner_subprocess_refuses_even_without_main_pid(self):
        unit = TWO_RUNNERS[0]
        group = self.root / "cgroups" / "system.slice" / unit
        group.mkdir(parents=True)
        (group / "cgroup.events").write_text("populated 1\nfrozen 0\n")
        self.units[unit]["ControlGroup"] = "/system.slice/" + unit
        self.save_units()
        self.refused()

    def test_untrusted_malformed_and_symlink_records_refuse(self):
        for body in [
            "cleanup-v1 123 123 0 POST /containers/prune\n",
            "garbage\n",
            "cleanup-v2 123 123 0 DELETE /unrelated\n",
            "cleanup-v2 123 123 0 DELETE /v5.0.0/libpod/containers/"
            + "a" * 64
            + "?force=true\n",
            "cleanup-v2 123 123 0 DELETE /v5.0.0/libpod/containers/../x?force=false\n",
            "cleanup-v2 123 123 0 POST /containers/prune\nextra\n",
        ]:
            self.owner.write_text(body)
            self.refused()
        self.owner.unlink()
        self.owner.symlink_to(self.root / "missing")
        self.refused()
        self.owner.unlink()

    def test_untrusted_modes_unknown_files_and_generation_formats_refuse(self):
        self.owner.chmod(0o644)
        self.refused()
        self.owner.chmod(0o600)
        unknown = self.fence / "unknown"
        unknown.touch(mode=0o600)
        self.refused()
        self.assertTrue(unknown.exists())
        unknown.unlink()
        for body in [
            "unknown 12345\n" * 2,
            APIS[0] + " 0\n" + APIS[1] + " 12345\n",
            "\n".join(unit + " 12345" for unit in reversed(APIS)) + "\n",
        ]:
            (self.fence / "api-generations").write_text(body)
            self.refused()

    def test_dangling_fence_and_cgroup_symlinks_refuse(self):
        destination = self.cgroup.with_name("different.slice")
        self.cgroup.rename(destination)
        self.cgroup.symlink_to(destination)
        self.refused()
        self.owner.unlink()
        (self.fence / "api-generations").unlink()
        self.fence.rmdir()
        self.fence.symlink_to(self.root / "missing")
        self.refused()
        for podman in ("0", "1"):
            self.assertEqual(
                self.run_script(
                    "podman-api-start-gate.sh", PODMAN_ADMISSION=podman
                ).returncode,
                1,
            )

    def test_replaced_owner_inode_during_proof_is_preserved(self):
        (self.root / "pause").touch()
        command, env = self.command("cleanup-fence-recover.sh")
        process = subprocess.Popen(
            command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        try:
            limit = time.monotonic() + 3
            while not (self.root / "checkpoint").exists():
                self.assertLess(time.monotonic(), limit)
                time.sleep(0.01)
            replacement = self.root / "replacement"
            replacement.write_text(self.owner.read_text())
            replacement.chmod(0o600)
            replacement.replace(self.owner)
            (self.root / "pause").unlink()
            process.communicate(timeout=4)
            self.assertEqual(process.returncode, 1)
            self.assertTrue(self.owner.exists())
        finally:
            (self.root / "pause").unlink(missing_ok=True)
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_registry_and_transition_markers_refuse_without_removing_anything(self):
        for marker in [
            "owned",
            "pending",
            "teardown-required",
            "drain-pending",
            "resume-pending",
            "drain-disowned",
        ]:
            path = self.state / marker
            path.symlink_to(self.root / "missing")
            self.refused()
            self.assertTrue(path.is_symlink())
            path.unlink()
        (self.state / "runner-units").write_text("\n".join(TWO_RUNNERS) + "\n\n")
        self.refused()
        (self.state / "runner-units").write_text(TWO_RUNNERS[0] + "\n")
        self.refused()

    def test_docker_only_gate_does_not_require_podman_registry(self):
        self.owner.unlink()
        (self.fence / "api-generations").unlink()
        self.fence.rmdir()
        (self.state / "runner-units").unlink()
        self.assertEqual(
            self.run_script(
                "podman-api-start-gate.sh", PODMAN_ADMISSION="0"
            ).returncode,
            0,
        )
        self.assertEqual(self.run_script("podman-api-start-gate.sh").returncode, 1)

    def test_api_gates_wait_on_recovery_lock_and_queued_starts_refuse_clear(self):
        for podman in ("0", "1"):
            with self.subTest(podman=podman):
                (self.root / "pause").touch()
                command, env = self.command("cleanup-fence-recover.sh")
                recovery = subprocess.Popen(
                    command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE
                )
                gate = None
                try:
                    limit = time.monotonic() + 3
                    while not (self.root / "checkpoint").exists():
                        self.assertLess(time.monotonic(), limit)
                        time.sleep(0.01)
                    with (
                        (self.state / "lifecycle.lock").open("a") as lock,
                        self.assertRaises(BlockingIOError),
                    ):
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    command, env = self.command(
                        "podman-api-start-gate.sh", PODMAN_ADMISSION=podman
                    )
                    gate = subprocess.Popen(
                        command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE
                    )
                    unit = APIS[int(podman)]
                    self.units[unit]["Job"] = "42"
                    self.units[unit]["ActiveState"] = "activating"
                    self.save_units()
                    self.assertIsNone(gate.poll())
                    (self.root / "pause").unlink()
                    recovery.communicate(timeout=4)
                    gate.communicate(timeout=4)
                    self.assertEqual(recovery.returncode, 1)
                    self.assertEqual(gate.returncode, 1)
                    self.assertTrue(self.fence.exists())
                    self.units[unit]["Job"] = ""
                    self.units[unit]["ActiveState"] = "inactive"
                    self.save_units()
                    (self.root / "checkpoint").unlink()
                finally:
                    (self.root / "pause").unlink(missing_ok=True)
                    for process in (recovery, gate):
                        if process and process.poll() is None:
                            process.kill()
                            process.communicate()


class ThreeRunnerRecoveryTests(RecoveryFixture, unittest.TestCase):
    """An extra Podman runner unit is part of the baked list and the proof."""

    runners = THREE_RUNNERS

    def test_extra_runner_cgroup_with_workers_refuses(self):
        group = self.root / "cgroups" / "system.slice" / EXTRA
        group.mkdir(parents=True)
        (group / "cgroup.events").write_text("populated 1\nfrozen 0\n")
        self.units[EXTRA]["ControlGroup"] = "/system.slice/" + EXTRA
        self.save_units()
        self.refused()
        (group / "cgroup.events").write_text("populated 0\nfrozen 0\n")
        self.assertEqual(self.run_script().returncode, 0)

    def test_two_runner_list_refuses_three_runner_state(self):
        self.refused(RUNNER_UNITS=" ".join(TWO_RUNNERS))

    def test_api_generations_follow_every_runner(self):
        # The API generation records start after the last runner.
        self.units[APIS[1]]["ExecMainStartTimestampMonotonic"] = "67890"
        self.save_units()
        self.refused()


if __name__ == "__main__":
    unittest.main()
