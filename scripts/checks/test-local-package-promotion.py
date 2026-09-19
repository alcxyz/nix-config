#!/usr/bin/env python3
"""Synthetic race and receipt checks for trusted local package promotion."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class LocalPackagePromotion(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config_remote, self.config_work = self.make_repository("config")
        self.packages_remote, self.packages_work = self.make_repository("packages")
        self.old_package = self.commit(self.packages_work, "version", "old\n", "old")
        self.new_package = self.commit(self.packages_work, "version", "new\n", "new")
        subprocess.run(["git", "-C", self.packages_work, "push", "origin", "HEAD:dev"], check=True)

        scripts = self.config_work / "scripts"
        (scripts / "ci").mkdir(parents=True)
        (scripts / "forgejo").mkdir(parents=True)
        shutil.copy(ROOT / "scripts/ci/check-package-promotion-readiness.sh", scripts / "ci")
        self.write_executable(
            scripts / "ci/verify-ai-package-stack.sh",
            """#!/usr/bin/env bash
set -eu
echo verify >> "$CALLS"
if [[ ${FAIL_VERIFY:-0} == 1 ]]; then exit 23; fi
if [[ ${ADVANCE_CONFIG:-0} == 1 ]]; then
  work=$(mktemp -d)
  git clone --quiet "$CONFIG_REMOTE" "$work"
  git -C "$work" switch --quiet dev
  echo advanced > "$work/advance"
  git -C "$work" add advance
  git -C "$work" -c user.name=fixture -c user.email=fixture@example.invalid commit --quiet -m advance
  git -C "$work" push --quiet origin HEAD:dev
fi
if [[ ${ADVANCE_PACKAGES:-0} == 1 ]]; then
  work=$(mktemp -d)
  git clone --quiet "$NIX_PACKAGES_REMOTE_URL" "$work"
  git -C "$work" switch --quiet dev
  echo advanced >> "$work/version"
  git -C "$work" add version
  git -C "$work" -c user.name=fixture -c user.email=fixture@example.invalid commit --quiet -m advance
  git -C "$work" push --quiet origin HEAD:dev
fi
""",
        )
        self.write_executable(
            scripts / "ci/check-configurations.sh",
            """#!/usr/bin/env bash
set -eu
echo "config:${1:-all}" >> "$CALLS"
""",
        )
        self.write_executable(
            scripts / "forgejo/commit-status.py",
            """#!/usr/bin/env python3
import os, sys
with open(os.environ["STATUS_LOG"], "a") as target:
    target.write(" ".join(sys.argv[1:]) + "\\n")
raise SystemExit(1 if sys.argv[1] == "require" else 0)
            """,
        )
        for fixture_script in (scripts / "ci").iterdir():
            fixture_script.write_text(
                fixture_script.read_text().replace("#!/usr/bin/env bash", f"#!{shutil.which('bash')}", 1)
            )
        (self.config_work / "flake.nix").write_text("{}\n")
        self.write_lock(self.config_work / "flake.lock", self.old_package)
        self.config_base = self.commit_all(self.config_work, "base")
        subprocess.run(["git", "-C", self.config_work, "push", "origin", "HEAD:dev"], check=True)

        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.write_executable(
            self.bin / "nix",
            """#!/usr/bin/env python3
import json, os
from pathlib import Path
path = Path("flake.lock")
data = json.loads(path.read_text())
data["nodes"]["nix-packages"]["locked"]["rev"] = os.environ["PRODUCER_REVISION"]
path.write_text(json.dumps(data) + "\\n")
""",
        )
        self.write_executable(
            self.bin / "curl",
            """#!/usr/bin/env python3
import json, os
from pathlib import Path
counter = Path(os.environ["QUEUE_COUNTER"])
count = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(count))
if os.environ.get("QUEUE_ALWAYS") == "1" or (os.environ.get("QUEUE_ON_SECOND") == "1" and count >= 2):
    print(json.dumps([{"head": {"ref": "update/fixture"}}]))
else:
    print("[]")
            """,
        )
        for mock in self.bin.iterdir():
            mock.write_text(
                mock.read_text()
                .replace("#!/usr/bin/env bash", f"#!{shutil.which('bash')}", 1)
                .replace("#!/usr/bin/env python3", f"#!{shutil.which('python3')}", 1)
            )
        self.calls = self.root / "calls"
        self.status_log = self.root / "statuses"
        self.queue_counter = self.root / "queue-count"
        self.token = self.root / "token"
        self.token.write_text("fixture\n")
        self.token.chmod(0o600)

    def make_repository(self, name):
        remote = self.root / f"{name}.git"
        work = self.root / f"{name}-work"
        subprocess.run(["git", "init", "--quiet", "--bare", remote], check=True)
        subprocess.run(["git", "init", "--quiet", "-b", "dev", work], check=True)
        subprocess.run(["git", "-C", work, "remote", "add", "origin", str(remote)], check=True)
        return remote, work

    @staticmethod
    def write_executable(path, text):
        path.write_text(text)
        path.chmod(0o755)

    @staticmethod
    def commit(work, name, content, message):
        (work / name).write_text(content)
        subprocess.run(["git", "-C", work, "add", name], check=True)
        subprocess.run(
            ["git", "-C", work, "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", message],
            check=True,
        )
        return subprocess.check_output(["git", "-C", work, "rev-parse", "HEAD"], text=True).strip()

    @staticmethod
    def commit_all(work, message):
        subprocess.run(["git", "-C", work, "add", "."], check=True)
        subprocess.run(
            ["git", "-C", work, "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", message],
            check=True,
        )
        return subprocess.check_output(["git", "-C", work, "rev-parse", "HEAD"], text=True).strip()

    @staticmethod
    def write_lock(path, revision):
        path.write_text(json.dumps({"nodes": {"nix-packages": {"locked": {"rev": revision}}}}) + "\n")

    def run_promoter(self, **extra):
        environment = {
            **os.environ,
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "CONFIG_REMOTE": self.config_remote.as_uri(),
            "CONFIG_BRANCH": "dev",
            "NIX_PACKAGES_REMOTE_URL": str(self.packages_remote),
            "NIX_PACKAGES_BRANCH": "dev",
            "NIX_PACKAGES_QUEUE_API_URL": "https://example.invalid/queue",
            "FORGEJO_URL": self.root.parent.as_uri(),
            "FORGEJO_OWNER": self.root.name,
            "FORGEJO_REPO": "config",
            "FORGEJO_STATUS_CONTEXT": "ci/local-configurations",
            "FORGEJO_API_TOKEN_FILE": str(self.token),
            "PRODUCER_REVISION": self.new_package,
            "CALLS": str(self.calls),
            "STATUS_LOG": str(self.status_log),
            "QUEUE_COUNTER": str(self.queue_counter),
            **extra,
        }
        return subprocess.run(
            ["bash", str(ROOT / "scripts/ci/run-local-package-promotion.sh")],
            env=environment,
            text=True,
            capture_output=True,
        )

    def remote_config_head(self):
        return subprocess.check_output(
            ["git", "--git-dir", self.config_remote, "rev-parse", "refs/heads/dev"], text=True
        ).strip()

    def test_changed_lock_is_verified_once_and_receipted_after_exact_push(self):
        result = self.run_promoter()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ["verify", "config:all"])
        self.assertNotEqual(self.remote_config_head(), self.config_base)
        statuses = self.status_log.read_text()
        self.assertIn("--state success", statuses)
        self.assertIn(f"--sha {self.remote_config_head()}", statuses)

    def test_queue_opened_during_validation_defers_without_push_or_success(self):
        result = self.run_promoter(QUEUE_ON_SECOND="1")
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertEqual(self.remote_config_head(), self.config_base)
        self.assertFalse(self.status_log.exists())

    def test_existing_queue_still_validates_current_configuration_head(self):
        result = self.run_promoter(QUEUE_ALWAYS="1")
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertEqual(self.remote_config_head(), self.config_base)
        self.assertEqual(self.calls.read_text().splitlines(), ["config:all"])
        statuses = self.status_log.read_text()
        self.assertIn("--state success", statuses)
        self.assertIn(f"--sha {self.config_base}", statuses)

    def test_producer_advance_during_validation_defers_without_push(self):
        result = self.run_promoter(ADVANCE_PACKAGES="1")
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertEqual(self.remote_config_head(), self.config_base)
        self.assertFalse(self.status_log.exists())

    def test_configuration_base_advance_during_validation_defers_candidate(self):
        result = self.run_promoter(ADVANCE_CONFIG="1")
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertNotEqual(self.remote_config_head(), self.config_base)
        self.assertFalse(self.status_log.exists())

    def test_failed_validation_never_pushes_or_publishes_success(self):
        result = self.run_promoter(FAIL_VERIFY="1")
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(self.remote_config_head(), self.config_base)
        self.assertFalse(self.status_log.exists())


if __name__ == "__main__":
    unittest.main()
