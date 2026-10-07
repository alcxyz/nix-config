#!/usr/bin/env python3
"""Exercise exact-head DMS merge gates against a local Git repository."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
MERGER = ROOT / "scripts/forgejo/merge-dms-plugins-lock.sh"
TOKEN = "synthetic-merge-secret"


class MergeQueue(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.remote = self.root / "remote.git"
        self.checkout = self.root / "checkout"
        self.git("init", "--bare", str(self.remote), cwd=self.root)
        self.git("clone", str(self.remote), str(self.checkout), cwd=self.root)
        self.git("config", "user.name", "Fixture", cwd=self.checkout)
        self.git("config", "user.email", "fixture@example.invalid", cwd=self.checkout)
        (self.checkout / "flake.lock").write_text("old\n")
        self.git("add", "flake.lock", cwd=self.checkout)
        self.git("commit", "-m", "base", cwd=self.checkout)
        self.git("branch", "-M", "dev", cwd=self.checkout)
        self.git("push", "origin", "dev", cwd=self.checkout)
        self.base = self.git("rev-parse", "HEAD", cwd=self.checkout).strip()
        self.git("switch", "-c", "update/dms-plugins-lock", cwd=self.checkout)
        (self.checkout / "flake.lock").write_text("new\n")
        self.git("add", "flake.lock", cwd=self.checkout)
        self.git("commit", "-m", "candidate", cwd=self.checkout)
        self.git("push", "origin", "update/dms-plugins-lock", cwd=self.checkout)
        self.head = self.git("rev-parse", "HEAD", cwd=self.checkout).strip()
        self.git("switch", "dev", cwd=self.checkout)

        bindir = self.root / "bin"
        bindir.mkdir()
        curl = bindir / "curl"
        curl.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
assert os.environ["TEST_TOKEN"] not in " ".join(args)
config = pathlib.Path(args[args.index("-K") + 1])
assert config.stat().st_mode & 0o777 == 0o600
assert os.environ["TEST_TOKEN"] in config.read_text()
url = next(arg for arg in args if arg.startswith("https://"))
http_status = "200"
head = os.environ.get("TEST_PR_HEAD") or os.environ["TEST_HEAD"]
base = os.environ.get("TEST_PR_BASE") or os.environ["TEST_BASE"]
pr = {"number": 47, "mergeable": True, "merge_base": base,
      "head": {"sha": head, "ref": "update/dms-plugins-lock",
               "repo": {"full_name": "fixture/config"}},
      "base": {"sha": base, "ref": "dev"}}
if "/pulls?state=open" in url:
    body = [pr]
elif url.endswith("/pulls/47"):
    if pathlib.Path(os.environ["TEST_MERGE_MARKER"]).exists():
        pr["head"]["sha"] = "3" * 40
    body = pr
elif "/commits/" in url and url.endswith("/status"):
    statuses = [
        {"id": 1, "context": "ci/dms-lock-build", "status": os.environ["TEST_BUILD_STATUS"]},
        {"id": 2, "context": "ci/dms-lock-validation",
         "status": os.environ["TEST_VALIDATION_STATUS"]}]
    if os.environ.get("TEST_NEWER_FAILURE") == "1":
        statuses.append({"id": 3, "context": "ci/dms-lock-build", "status": "failure"})
    if os.environ.get("TEST_NEWER_VALIDATION_PENDING") == "1":
        statuses.append({"id": 4, "context": "ci/dms-lock-validation", "status": "pending"})
    body = {"statuses": statuses}
    if os.environ.get("TEST_MOVE_AFTER_STATUS") == "1":
        pathlib.Path(os.environ["TEST_MERGE_MARKER"]).touch()
elif url.endswith("/pulls/47/merge"):
    payload = json.loads(pathlib.Path(args[args.index("--data") + 1][1:]).read_text())
    assert payload["head_commit_id"] == os.environ["TEST_HEAD"]
    pathlib.Path(os.environ["TEST_MERGE_MARKER"]).touch()
    if os.environ.get("TEST_REJECT_BRANCH_DELETION") == "1" and payload.get("delete_branch_after_merge"):
        http_status = "403"
    body = {}
else:
    raise AssertionError(url)
pathlib.Path(args[args.index("-o") + 1]).write_text(json.dumps(body))
if "-w" in args:
    print(http_status)
''')
        curl.chmod(0o700)
        self.marker = self.root / "merged"
        self.env = os.environ.copy()
        self.env.update({
            "PATH": f"{bindir}:{os.environ['PATH']}",
            "TEST_TOKEN": TOKEN,
            "TEST_HEAD": self.head,
            "TEST_BASE": self.base,
            "TEST_BUILD_STATUS": "success",
            "TEST_VALIDATION_STATUS": "success",
            "TEST_MERGE_MARKER": str(self.marker),
            "FORGEJO_TOKEN": TOKEN,
            "FORGEJO_URL": "https://forgejo.invalid",
            "FORGEJO_OWNER": "fixture",
            "FORGEJO_REPO": "config",
            "BASE_BRANCH": "dev",
            "UPDATE_BRANCH": "update/dms-plugins-lock",
        })

    @staticmethod
    def git(*args, cwd):
        return subprocess.check_output(["git", *args], cwd=cwd, text=True, stderr=subprocess.DEVNULL)

    def run_queue(self):
        return subprocess.run(["bash", str(MERGER)], cwd=self.checkout, env=self.env,
                              text=True, capture_output=True)

    def test_only_exact_green_lock_commit_merges(self):
        result = self.run_queue()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.marker.exists())
        self.assertNotIn(TOKEN, result.stdout + result.stderr)

    def test_pending_and_missing_receipts_wait(self):
        for key in ("TEST_BUILD_STATUS", "TEST_VALIDATION_STATUS"):
            for state in ("pending", "missing"):
                with self.subTest(key=key, state=state):
                    self.env[key] = state
                    result = self.run_queue()
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertFalse(self.marker.exists())
                    self.env[key] = "success"

    def test_merge_succeeds_without_optional_branch_deletion_permission(self):
        self.env["TEST_REJECT_BRANCH_DELETION"] = "1"
        result = self.run_queue()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.marker.exists())
        self.assertIn("Merged verified DMS lock update PR", result.stdout)

    def test_failed_build_or_validation_never_merges(self):
        for key in ("TEST_BUILD_STATUS", "TEST_VALIDATION_STATUS"):
            with self.subTest(key=key):
                self.env[key] = "failure"
                result = self.run_queue()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.marker.exists())
                self.env[key] = "success"

    def test_stale_head_or_base_never_merges(self):
        for key in ("TEST_PR_HEAD", "TEST_PR_BASE"):
            with self.subTest(key=key):
                self.env[key] = "4" * 40
                result = self.run_queue()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.marker.exists())
                self.env.pop(key)

    def test_extra_changed_path_never_merges(self):
        self.git("switch", "update/dms-plugins-lock", cwd=self.checkout)
        (self.checkout / "extra.txt").write_text("unexpected\n")
        self.git("add", "extra.txt", cwd=self.checkout)
        self.git("commit", "--amend", "--no-edit", cwd=self.checkout)
        self.git("push", "--force-with-lease", "origin", "update/dms-plugins-lock", cwd=self.checkout)
        self.env["TEST_HEAD"] = self.git("rev-parse", "HEAD", cwd=self.checkout).strip()
        self.git("switch", "dev", cwd=self.checkout)
        result = self.run_queue()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_head_movement_after_status_never_merges(self):
        self.env["TEST_MOVE_AFTER_STATUS"] = "1"
        result = self.run_queue()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("moved", result.stderr)

    def test_latest_receipt_overrides_older_success(self):
        self.env["TEST_NEWER_FAILURE"] = "1"
        result = self.run_queue()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_latest_pending_validation_overrides_older_success(self):
        self.env["TEST_NEWER_VALIDATION_PENDING"] = "1"
        result = self.run_queue()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
