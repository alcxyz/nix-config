#!/usr/bin/env python3
"""Exercise canary log lifecycle with a fake API; never contact a runtime."""

import ctypes
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".forgejo/workflows/podman-canary.yml"
MOCK_DOCKER = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import sys
import time

root = Path(os.environ["FIXTURE_STATE"])
mode = os.environ["FIXTURE_MODE"]
args = sys.argv[1:]
with (root / "calls").open("a") as trace:
    trace.write(" ".join(args) + "\n")
command = args[0]
name = args[args.index("--name") + 1] if command == "create" else args[-1]
state = root / name
if command == "info":
    print("journald")
elif command == "create":
    state.mkdir()
    (state / "status").write_text(args[-1] if "-exit-" in name else "0")
elif command == "start":
    (state / "running").touch()
elif command == "inspect":
    print("true" if (state / "running").exists() and mode != "already-exited" else "false")
elif command == "exec":
    name = args[1]
    (root / name / "released").touch()
elif command == "logs":
    (state / "follower-pid").write_text(str(os.getpid()))
    if Path("/proc/self/stat").exists():
        (state / "follower-start").write_text(Path("/proc/self/stat").read_text().rsplit(")", 1)[1].split()[19])
    if mode == "ignore-term":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if mode == "no-early":
        while True:
            time.sleep(1)
    print("early-" + name, flush=True)
    while (state / "running").exists():
        time.sleep(0.01)
    # Deliberately deliver final records after docker wait has returned.
    time.sleep(0.07)
    if mode != "missing-late" and "-exit-" in name:
        print("late-" + name, flush=True)
        if mode != "missing-stderr":
            print("late-stderr-" + name, file=sys.stderr, flush=True)
    if mode == "follower-error":
        sys.exit(23)
    if mode in ("open-stream", "ignore-term"):
        while True:
            time.sleep(1)
elif command == "wait":
    while not (state / "released").exists():
        time.sleep(0.01)
    (state / "running").unlink()
    if mode == "wait-error":
        sys.exit(23)
    status = {"wrong-status": "0", "invalid-status": "999", "malformed-status": "not-a-status"}.get(mode, (state / "status").read_text())
    print(status)
elif command in ("kill", "rm"):
    (state / "running").unlink(missing_ok=True)
    if command == "rm":
        (state / "removed").touch()
        if mode == "cleanup-error":
            sys.exit(23)
else:
    raise SystemExit("Unexpected fixture command: " + repr(args))
'''


def live_script():
    text = WORKFLOW.read_text()
    step = text.split("      - name: Bounded live logs and exact container statuses\n", 1)[1]
    block = step.split("        run: |\n", 1)[1].split("      - name:", 1)[0]
    script = "\n".join(line[10:] for line in block.splitlines()) + "\n"
    script = re.sub(r"\$\{\{ forgejo\.run_id \}\}", "123", script)
    script = re.sub(r"\$\{\{ forgejo\.run_attempt \}\}", "2", script)
    return script


class CanaryLogs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Adopt orphaned grandchildren on Linux, like a container PID 1 that
        # does not reap them. Leaked zombies must fail the teardown assertion.
        cls.libc = None
        if sys.platform.startswith("linux"):
            cls.libc = ctypes.CDLL(None, use_errno=True)
            cls.previous_subreaper = ctypes.c_int()
            if cls.libc.prctl(37, ctypes.byref(cls.previous_subreaper), 0, 0, 0) != 0:
                raise OSError(ctypes.get_errno(), "PR_GET_CHILD_SUBREAPER")
            if cls.libc.prctl(36, 1, 0, 0, 0) != 0:
                raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")

    @classmethod
    def tearDownClass(cls):
        if cls.libc is not None:
            # Reap exited adopted processes after assertions, never to hide a
            # teardown failure. This standalone test process owns these children.
            while True:
                try:
                    if os.waitpid(-1, os.WNOHANG)[0] == 0:
                        break
                except ChildProcessError:
                    break
            cls.libc.prctl(36, cls.previous_subreaper.value, 0, 0, 0)

    def run_fixture(self, mode):
        with tempfile.TemporaryDirectory(prefix="podman-log-fixture-") as temporary:
            root = Path(temporary)
            binary = root / "bin"
            binary.mkdir()
            docker = binary / "docker"
            docker.write_text(MOCK_DOCKER.replace("#!/usr/bin/env python3", "#!" + sys.executable, 1))
            docker.chmod(0o755)
            state = root / "state"
            state.mkdir()
            # Shorten only polling and fixture deadlines for offline checks.
            # The workflow's real timeout/kill/wait processes still execute.
            script = live_script().replace("sleep 1", "sleep 0.03")
            script = script.replace("5s no", "0.2s no").replace("-k 2s", "-k 0.1s")
            started = time.monotonic()
            result = subprocess.run(
                ["bash", "-c", script],
                env={
                    "PATH": str(binary) + os.pathsep + os.environ["PATH"],
                    "FIXTURE_STATE": str(state),
                    "FIXTURE_MODE": mode,
                },
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertLess(time.monotonic() - started, 5)
            self.assertTrue((state / "calls").exists(), result.stderr)
            calls = (state / "calls").read_text().splitlines()
            created = [
                parts[parts.index("--name") + 1]
                for line in calls if line.startswith("create ")
                for parts in [line.split()]
            ]
            removed = [line.split()[-1] for line in calls if line.startswith("rm ")]
            self.assertEqual(removed, created, result.stderr)
            self.assertTrue(all(name.startswith("canary-logs-123-2-") for name in removed))
            self.assertTrue(all((state / name / "removed").exists() for name in created))
            self.assertFalse(any((state / name / "running").exists() for name in created))
            for name in created:
                pid_file = state / name / "follower-pid"
                if pid_file.exists():
                    pid = int(pid_file.read_text())
                    start_file = state / name / "follower-start"
                    process_stat = Path("/proc", str(pid), "stat")
                    if start_file.exists() and process_stat.exists():
                        # PID reuse is harmless; a surviving process with the
                        # original identity (including a zombie) is not.
                        current_start = process_stat.read_text().rsplit(")", 1)[1].split()[19]
                        if current_start != start_file.read_text():
                            continue
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)
            self.assertFalse(any("prune" in line or line.startswith("image ") for line in calls))
            self.assertTrue(all(" -a" not in line for line in calls if line.startswith("start ")))
            return result

    def test_closed_stream_preserves_status_and_late_logs(self):
        result = self.run_fixture("close-stream")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Preserved container status 37 with complete late output", result.stdout)
        self.assertIn("Stuck container returned bounded timeout 124", result.stdout)
        self.assertIn("late-stderr-canary-logs-123-2-exit-37", result.stdout)

    def test_open_stream_is_drained_then_terminated(self):
        result = self.run_fixture("open-stream")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("late-canary-logs-123-2-exit-37", result.stdout)

    def test_unresponsive_follower_is_killed_and_reaped(self):
        result = self.run_fixture("ignore-term")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("late-stderr-canary-logs-123-2-exit-37", result.stdout)

    def test_no_early_output_fails_and_cleans_up(self):
        result = self.run_fixture("no-early")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No early log record", result.stderr)

    def test_missing_late_output_fails(self):
        self.assertNotEqual(self.run_fixture("missing-late").returncode, 0)

    def test_missing_terminal_stderr_fails(self):
        self.assertNotEqual(self.run_fixture("missing-stderr").returncode, 0)

    def test_invalid_container_status_fails(self):
        for mode in ("invalid-status", "malformed-status"):
            with self.subTest(mode=mode):
                self.assertNotEqual(self.run_fixture(mode).returncode, 0)

    def test_wrong_container_status_fails(self):
        self.assertNotEqual(self.run_fixture("wrong-status").returncode, 0)

    def test_early_output_after_exit_fails(self):
        self.assertNotEqual(self.run_fixture("already-exited").returncode, 0)

    def test_follower_error_fails(self):
        result = self.run_fixture("follower-error")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Log follower failed: 23", result.stderr)

    def test_wait_api_error_fails(self):
        self.assertNotEqual(self.run_fixture("wait-error").returncode, 0)

    def test_cleanup_error_fails(self):
        result = self.run_fixture("cleanup-error")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Fixture container cleanup failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
