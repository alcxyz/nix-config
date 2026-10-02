#!/usr/bin/env python3
"""Synthetic checks for locking nix-packages to the promoted revision."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/update-inputs/lock-promoted-packages.sh"
FIXTURE_IDENTITY = ["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid"]


class LockPromotedPackages(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

        self.packages = self.root / "packages.git"
        work = self.root / "packages-work"
        subprocess.run(["git", "init", "--quiet", "--bare", self.packages], check=True)
        subprocess.run(["git", "init", "--quiet", "-b", "dev", work], check=True)
        self.old_package = self.commit(work, "old\n")
        self.new_package = self.commit(work, "new\n")
        subprocess.run(["git", "-C", work, "push", "--quiet", self.packages, "HEAD:refs/heads/dev"], check=True)

        self.config = self.root / "config"
        self.config.mkdir()
        self.write_lock(self.old_package, 1)

        self.bin = self.root / "bin"
        self.bin.mkdir()
        nix = self.bin / "nix"
        nix.write_text(
            f"""#!{shutil.which('python3')}
import json, os, sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
rev = parse_qs(urlsplit(sys.argv[-1].removeprefix("git+")).query)["rev"][0]
if sys.argv[1:3] == ["flake", "metadata"]:
    print(json.dumps({{"locked": {{"revCount": int(os.environ["REV_COUNTS"].split(",")[rev == os.environ["NEW"]])}}}}))
elif sys.argv[1:3] == ["flake", "lock"]:
    path = Path("flake.lock")
    data = json.loads(path.read_text())
    data["nodes"]["nix-packages"]["locked"]["rev"] = rev
    if os.environ.get("CHANGE_ORIGINAL") == "1":
        data["nodes"]["nix-packages"]["original"]["rev"] = rev
    path.write_text(json.dumps(data) + "\\n")
else:
    raise SystemExit(2)
"""
        )
        nix.chmod(0o755)

    @staticmethod
    def commit(work, content):
        (work / "version").write_text(content)
        subprocess.run(["git", "-C", work, "add", "version"], check=True)
        subprocess.run(["git", "-C", work, *FIXTURE_IDENTITY, "commit", "--quiet", "-m", content.strip()], check=True)
        return subprocess.check_output(["git", "-C", work, "rev-parse", "HEAD"], text=True).strip()

    def write_lock(self, revision, count):
        url = self.packages.as_uri()
        node = {
            "locked": {"type": "git", "url": url, "ref": "dev", "rev": revision, "revCount": count},
            "original": {"type": "git", "url": url, "ref": "dev"},
        }
        (self.config / "flake.lock").write_text(json.dumps({"nodes": {"nix-packages": node}}) + "\n")

    def locked(self):
        return json.loads((self.config / "flake.lock").read_text())["nodes"]["nix-packages"]["locked"]["rev"]

    def promote(self, revision):
        subprocess.run(["git", "--git-dir", self.packages, "update-ref", "refs/heads/promoted", revision], check=True)

    def run_script(self, *arguments, rev_counts="1,2", **extra):
        environment = {
            **os.environ,
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "NEW": self.new_package,
            "REV_COUNTS": rev_counts,
            **extra,
        }
        return subprocess.run(
            ["bash", str(SCRIPT), *arguments], cwd=self.config, env=environment, text=True, capture_output=True
        )

    def test_lagging_lock_moves_to_promoted(self):
        self.promote(self.new_package)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.locked(), self.new_package)
        self.assertIn("commit flake.lock", result.stderr)

    def test_current_lock_is_left_alone(self):
        self.promote(self.old_package)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already locked", result.stderr)

    def test_older_promotion_never_downgrades(self):
        self.promote(self.new_package)
        result = self.run_script(rev_counts="1,1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.locked(), self.old_package)
        self.assertIn("not older", result.stderr)

    def test_unknown_lock_age_is_never_replaced(self):
        self.promote(self.new_package)
        lock = json.loads((self.config / "flake.lock").read_text())
        del lock["nodes"]["nix-packages"]["locked"]["revCount"]
        (self.config / "flake.lock").write_text(json.dumps(lock))
        result = self.run_script()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.locked(), self.old_package)

    def test_changed_original_is_reported(self):
        self.promote(self.new_package)
        result = self.run_script(CHANGE_ORIGINAL="1")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("does not match", result.stderr)

    def test_missing_promotion_fails_the_update(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.locked(), self.old_package)

    def test_option_like_url_is_never_passed_to_git(self):
        lock = json.loads((self.config / "flake.lock").read_text())
        lock["nodes"]["nix-packages"]["original"]["url"] = "--upload-pack=touch pwned;"
        (self.config / "flake.lock").write_text(json.dumps(lock))
        self.assertEqual(self.run_script("--check").returncode, 0)
        self.assertEqual(self.run_script().returncode, 1)
        self.assertFalse((self.config / "pwned").exists())

    def test_check_warns_without_changing_the_lock(self):
        self.promote(self.new_package)
        result = self.run_script("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.locked(), self.old_package)
        self.assertIn("just lock-packages", result.stderr)

    def test_check_is_silent_when_current_unresolvable_or_elsewhere(self):
        self.promote(self.old_package)
        self.assertEqual(self.run_script("--check").stderr, "")
        subprocess.run(["git", "--git-dir", self.packages, "update-ref", "-d", "refs/heads/promoted"], check=True)
        self.assertEqual(self.run_script("--check").stderr, "")
        (self.config / "flake.lock").unlink()
        result = self.run_script("--check")
        self.assertEqual((result.returncode, result.stderr), (0, ""))


if __name__ == "__main__":
    unittest.main()
