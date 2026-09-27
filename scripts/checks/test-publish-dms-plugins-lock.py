#!/usr/bin/env python3
"""Exercise the DMS publisher without a Forgejo token or network access."""

import base64
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PUBLISHER = ROOT / "scripts/forgejo/publish-dms-plugins-lock.sh"
TOKEN = "synthetic-publisher-secret"
HEAD = "1" * 40
BASE = "2" * 40


class Publisher(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        bindir = self.root / "bin"
        bindir.mkdir()
        self.calls = self.root / "calls"
        self.write_executable(
            bindir / "git",
            '''#!/bin/sh
printf 'git %s\n' "$*" >>"$CALL_LOG"
case "$1" in
  diff) case "$*" in *--name-only*) echo flake.lock; exit 0 ;; esac; exit 1 ;;
  status) printf '%s\n' "${TEST_WORKTREE_STATUS:- M flake.lock}"; exit 0 ;;
  rev-parse)
    case "$2" in
      HEAD) if [ -f "$TEST_COMMITTED" ]; then echo "$TEST_HEAD"; else echo "$TEST_BASE"; fi ;;
      origin/dev) echo "$TEST_BASE" ;;
      "$TEST_HEAD^" ) echo "${TEST_REMOTE_PARENT:-$TEST_BASE}" ;;
      "$TEST_HEAD:flake.lock" ) echo blob ;;
      *) echo "$TEST_HEAD" ;;
    esac
    exit 0 ;;
  hash-object) echo blob; exit 0 ;;
  commit) : >"$TEST_COMMITTED" ;;
  ls-remote | push)
    [ "$GIT_CONFIG_COUNT" = 2 ] || exit 11
    [ "$GIT_CONFIG_KEY_0" = "$GIT_CONFIG_KEY_1" ] || exit 12
    [ -z "$GIT_CONFIG_VALUE_0" ] || exit 13
    case "$GIT_CONFIG_VALUE_1" in *"AUTHORIZATION: basic "*) ;; *) exit 14 ;; esac
    if [ "$1" = ls-remote ] && [ -n "${TEST_REMOTE_REF:-}" ]; then
      printf '%s\trefs/heads/update/dms-plugins-lock\n' "$TEST_REMOTE_REF"
    fi
    ;;
esac
exit 0
''',
        )
        self.write_executable(
            bindir / "curl",
            '''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
assert os.environ["TEST_TOKEN"] not in " ".join(args)
config = pathlib.Path(args[args.index("-K") + 1])
assert config.stat().st_mode & 0o777 == 0o600
assert os.environ["TEST_TOKEN"] in config.read_text()
url = next(arg for arg in args if arg.startswith("http://") or arg.startswith("https://"))
status = "201"
if url.endswith("/pulls"):
    if os.environ.get("TEST_PR_EXISTS") == "1":
        body = {"message": "already exists"}
        status = "422"
    else:
        body = {"number": 47}
elif url.endswith("/pulls/47"):
    body = {"number": int(os.environ.get("TEST_PR_NUMBER", "47")),
            "state": os.environ.get("TEST_PR_STATE", "open"),
            "mergeable": os.environ.get("TEST_PR_MERGEABLE", "true") == "true",
            "head": {"sha": os.environ.get("TEST_PR_HEAD_SHA", os.environ["TEST_HEAD"]),
                     "ref": os.environ.get("TEST_PR_HEAD_REF", "update/dms-plugins-lock"),
                     "repo": {"full_name": os.environ.get("TEST_PR_HEAD_REPO", "fixture/config")}},
            "base": {"sha": os.environ.get("TEST_PR_BASE_SHA", os.environ["TEST_BASE"]),
                     "ref": os.environ.get("TEST_PR_BASE_REF", "dev")},
            "merge_base": os.environ.get("TEST_PR_MERGE_BASE", os.environ["TEST_BASE"])}
elif "/dispatches" in url:
    body = {}
    status = os.environ.get("TEST_DISPATCH_STATUS", "201")
    payload = json.loads(pathlib.Path(args[args.index("--data") + 1][1:]).read_text())
    assert payload["ref"] == os.environ["TEST_HEAD"]
    open(os.environ["CALL_LOG"], "a").write("dispatch exact head\\n")
elif "/pulls?state=open" in url:
    body = [{"number": 47, "head": {"ref": "update/dms-plugins-lock",
            "repo": {"full_name": "fixture/config"}}}]
else:
    raise AssertionError(url)
pathlib.Path(args[args.index("-o") + 1]).write_text(json.dumps(body))
if "-w" in args:
    print(status)
''',
        )
        self.write_executable(
            bindir / "python3",
            '''#!/bin/sh
if [ "$1" = "SCRIPT" ]; then
  printf 'status %s\n' "$*" >>"$CALL_LOG"
  case "$2" in
    require) exit 1 ;;
    publish) exit 0 ;;
  esac
fi
exec "REAL_PYTHON" "$@"
'''.replace("SCRIPT", str(ROOT / "scripts/forgejo/commit-status.py")).replace(
                "REAL_PYTHON", subprocess.check_output(["which", "python3"], text=True).strip()
            ),
        )
        self.env = os.environ.copy()
        self.env.update(
            {
                "PATH": f"{bindir}:{os.environ['PATH']}",
                "CALL_LOG": str(self.calls),
                "TEST_TOKEN": TOKEN,
                "TEST_HEAD": HEAD,
                "TEST_BASE": BASE,
                "TEST_COMMITTED": str(self.root / "committed"),
                "FORGEJO_TOKEN": TOKEN,
                "FORGEJO_URL": "https://forgejo.invalid",
                "FORGEJO_OWNER": "fixture",
                "FORGEJO_REPO": "config",
                "BASE_BRANCH": "dev",
                "UPDATE_BRANCH": "update/dms-plugins-lock",
                "REVISION": "abc123",
                "VERSION": "1.2.3",
            }
        )

    @staticmethod
    def write_executable(path, content):
        path.write_text(content)
        path.chmod(0o700)

    def run_publisher(self):
        return subprocess.run(
            ["bash", str(PUBLISHER)], cwd=self.root, env=self.env, text=True, capture_output=True
        )

    def test_publishes_build_receipt_and_dispatches_exact_head_without_merge(self):
        result = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text()
        self.assertIn(f"--sha {HEAD} --context ci/dms-lock-build", calls)
        self.assertIn("dispatch exact head", calls)
        self.assertNotIn("/merge", calls)
        self.assertNotIn(TOKEN, calls + result.stdout + result.stderr)
        self.assertNotIn(base64.b64encode(f"fixture:{TOKEN}".encode()).decode(), calls)

    def test_rejects_unverified_worktree_before_commit_or_push(self):
        for status in (
            " M flake.lock\n M flake.nix",
            " M flake.lock\nA  extra.txt",
            " M flake.lock\n?? extra.txt",
        ):
            with self.subTest(status=status):
                self.env["TEST_WORKTREE_STATUS"] = status
                result = self.run_publisher()
                self.assertNotEqual(result.returncode, 0)
                calls = self.calls.read_text()
                self.assertNotIn("git commit", calls)
                self.assertNotIn("git push", calls)
                self.assertNotIn("dispatch", calls)
                self.assertNotIn("\nstatus ", calls)
                self.calls.unlink()

    def test_reuses_unchanged_candidate_without_rewriting_its_head(self):
        self.env["TEST_REMOTE_REF"] = HEAD
        self.env["TEST_PR_EXISTS"] = "1"
        result = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text()
        self.assertNotIn("git commit", calls)
        self.assertNotIn("git push", calls)
        self.assertIn("dispatch exact head", calls)

    def test_dispatch_accepts_no_content_response(self):
        self.env["TEST_DISPATCH_STATUS"] = "204"
        result = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("dispatch exact head", self.calls.read_text())

    def test_delayed_pr_metadata_still_receipts_pushed_exact_head(self):
        self.env.update({"TEST_PR_MERGEABLE": "false", "TEST_PR_HEAD_SHA": "",
                         "TEST_PR_BASE_SHA": "", "TEST_PR_MERGE_BASE": ""})
        result = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text()
        self.assertIn(f"--sha {HEAD} --context ci/dms-lock-build", calls)
        self.assertIn("dispatch exact head", calls)

    def test_wrong_pr_identity_blocks_receipt_and_dispatch(self):
        for key, value in (
            ("TEST_PR_NUMBER", "48"),
            ("TEST_PR_STATE", "closed"),
            ("TEST_PR_HEAD_REF", "other-branch"),
            ("TEST_PR_HEAD_REPO", "other/repo"),
            ("TEST_PR_BASE_REF", "main"),
        ):
            with self.subTest(key=key):
                self.env[key] = value
                result = self.run_publisher()
                self.assertNotEqual(result.returncode, 0)
                calls = self.calls.read_text()
                self.assertNotIn("\nstatus ", calls)
                self.assertNotIn("dispatch exact head", calls)
                self.calls.unlink()
                del self.env[key]

    def test_stale_candidate_is_replaced_from_current_base(self):
        self.env["TEST_REMOTE_REF"] = HEAD
        self.env["TEST_REMOTE_PARENT"] = "4" * 40
        result = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text()
        self.assertIn("git commit", calls)
        self.assertIn("git push --force-with-lease", calls)


if __name__ == "__main__":
    unittest.main()
