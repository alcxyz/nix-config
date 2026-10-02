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
        (scripts / "ci/check-configurations.sh").write_text(
            """#!/usr/bin/env bash
set -eu
echo "config:${1:-all}" >> "$CALLS"
if [[ ${FAIL_CONFIG:-0} == 1 ]]; then exit 29; fi
if [[ ${FAIL_HEAD_CONFIG:-0} == 1 ]] && ! grep -q "$PRODUCER_REVISION" flake.lock; then exit 31; fi
if [[ -n ${CHECK_RESULTS_OUT_LINK:-} ]]; then ln -s /nix/store/fixture-check "$CHECK_RESULTS_OUT_LINK"; fi
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
            "NIX_PACKAGES_REMOTE_URL": self.packages_remote.as_uri(),
            "NIX_PACKAGES_BRANCH": "dev",
            "NIX_PACKAGES_PROMOTED_BRANCH": "promoted",
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
            # Keep the run lock away from a live promoter on the same host.
            "XDG_RUNTIME_DIR": str(self.root),
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

    def remote_promoted(self):
        result = subprocess.run(
            ["git", "--git-dir", self.packages_remote, "rev-parse", "--verify", "--quiet", "refs/heads/promoted"],
            text=True,
            capture_output=True,
        )
        return result.stdout.strip() or None

    def set_promoted(self, revision):
        subprocess.run(
            ["git", "--git-dir", self.packages_remote, "update-ref", "refs/heads/promoted", revision], check=True
        )

    def success_receipts(self):
        if not self.status_log.exists():
            return []
        return [line.split("--sha ")[1].split()[0] for line in self.status_log.read_text().splitlines() if "--state success" in line]

    def test_changed_producer_is_verified_once_and_promoted_without_config_commit(self):
        self.assertFalse(os.access(self.config_work / "scripts/ci/check-configurations.sh", os.X_OK))
        result = self.run_promoter()
        self.assertEqual(result.returncode, 0, result.stderr)
        # The unchanged head is receipted first, then the candidate is verified.
        self.assertEqual(self.calls.read_text().splitlines(), ["config:all", "verify", "config:all"])
        self.assertEqual(self.remote_config_head(), self.config_base)
        self.assertEqual(self.remote_promoted(), self.new_package)
        self.assertEqual(self.success_receipts(), [self.config_base])

    def test_previous_promotion_is_replaced(self):
        self.set_promoted(self.old_package)
        result = self.run_promoter()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.remote_promoted(), self.new_package)

    def test_current_promotion_only_validates_configuration_head(self):
        self.set_promoted(self.new_package)
        result = self.run_promoter()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ["config:all"])
        self.assertEqual(self.remote_config_head(), self.config_base)
        self.assertIn(f"--sha {self.config_base}", self.status_log.read_text())

    def test_locked_producer_is_promoted_after_head_validation(self):
        self.write_lock(self.config_work / "flake.lock", self.new_package)
        head = self.commit_all(self.config_work, "lock")
        subprocess.run(["git", "-C", self.config_work, "push", "origin", "HEAD:dev"], check=True)
        result = self.run_promoter()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ["config:all", "verify"])
        self.assertIn(f"--sha {head} --context ci/local-configurations --token-file", self.status_log.read_text())
        self.assertEqual(self.remote_promoted(), self.new_package)

    def test_failed_head_validation_does_not_promote_locked_producer(self):
        self.write_lock(self.config_work / "flake.lock", self.new_package)
        self.commit_all(self.config_work, "lock")
        subprocess.run(["git", "-C", self.config_work, "push", "origin", "HEAD:dev"], check=True)
        result = self.run_promoter(FAIL_CONFIG="1")
        self.assertEqual(result.returncode, 29, result.stderr)
        self.assertIsNone(self.remote_promoted())

    def test_queue_opened_during_validation_defers_without_promotion(self):
        result = self.run_promoter(QUEUE_ON_SECOND="1")
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertIsNone(self.remote_promoted())
        self.assertEqual(self.success_receipts(), [self.config_base])

    def test_existing_queue_still_validates_current_configuration_head(self):
        result = self.run_promoter(QUEUE_ALWAYS="1")
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertIsNone(self.remote_promoted())
        self.assertEqual(self.calls.read_text().splitlines(), ["config:all"])
        statuses = self.status_log.read_text()
        self.assertIn("--state success", statuses)
        self.assertIn(f"--sha {self.config_base}", statuses)

    def test_producer_advance_during_validation_defers_without_promotion(self):
        result = self.run_promoter(ADVANCE_PACKAGES="1")
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertIsNone(self.remote_promoted())
        self.assertEqual(self.success_receipts(), [self.config_base])

    def test_configuration_advance_during_validation_still_promotes(self):
        result = self.run_promoter(ADVANCE_CONFIG="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(self.remote_config_head(), self.config_base)
        self.assertEqual(self.remote_promoted(), self.new_package)

    def test_failed_validation_never_promotes(self):
        result = self.run_promoter(FAIL_VERIFY="1")
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(self.remote_config_head(), self.config_base)
        self.assertIsNone(self.remote_promoted())
        self.assertEqual(self.success_receipts(), [self.config_base])

    def test_failed_head_still_promotes_fixing_candidate(self):
        result = self.run_promoter(FAIL_HEAD_CONFIG="1")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ["config:all", "verify", "config:all"])
        self.assertEqual(self.remote_promoted(), self.new_package)
        self.assertIn(f"--sha {self.config_base} --context ci/local-configurations --token-file {self.token} --state failure", self.status_log.read_text())
        self.assertEqual(self.success_receipts(), [])

    def test_failed_head_still_fails_a_deferred_promotion(self):
        result = self.run_promoter(FAIL_HEAD_CONFIG="1", QUEUE_ON_SECOND="1")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIsNone(self.remote_promoted())

    def test_failed_head_and_candidate_never_promote(self):
        result = self.run_promoter(FAIL_CONFIG="1")
        self.assertEqual(result.returncode, 29, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ["config:all", "verify", "config:all"])
        self.assertIsNone(self.remote_promoted())

    def test_successful_validation_replaces_previous_check_roots(self):
        roots = self.root / "check-roots"
        previous = roots / "run.previous"
        previous.mkdir(parents=True)
        (previous / "check").symlink_to("/nix/store/previous-check")
        (previous / "complete").touch()
        result = self.run_promoter(CHECK_RESULTS_ROOT_DIR=str(roots))
        self.assertEqual(result.returncode, 0, result.stderr)
        runs = list(roots.iterdir())
        self.assertEqual(len(runs), 1)
        self.assertNotEqual(runs[0], previous)
        self.assertEqual(os.readlink(runs[0] / "check"), "/nix/store/fixture-check")
        self.assertTrue((runs[0] / "complete").exists())

    def test_failed_validation_keeps_previous_check_roots(self):
        roots = self.root / "check-roots"
        previous = roots / "run.previous"
        previous.mkdir(parents=True)
        (previous / "check").symlink_to("/nix/store/previous-check")
        (previous / "complete").touch()
        interrupted = roots / "run.interrupted"
        interrupted.mkdir()
        (interrupted / "check").symlink_to("/nix/store/partial-check")
        result = self.run_promoter(CHECK_RESULTS_ROOT_DIR=str(roots), FAIL_CONFIG="1")
        self.assertEqual(result.returncode, 29, result.stderr)
        self.assertEqual(list(roots.iterdir()), [previous])
        self.assertIsNone(self.remote_promoted())
        self.assertNotIn("--state success", self.status_log.read_text() if self.status_log.exists() else "")

if __name__ == "__main__":
    unittest.main()
