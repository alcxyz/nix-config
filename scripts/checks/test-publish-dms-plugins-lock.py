#!/usr/bin/env python3
"""Exercise the DMS lock publisher with synthetic git, curl, and status clients."""

import os
import base64
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PUBLISHER = ROOT / "scripts/forgejo/publish-dms-plugins-lock.sh"
TOKEN = "synthetic-publisher-secret"
ENCODED_AUTH = base64.b64encode(f"fixture:{TOKEN}".encode()).decode()
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
printf 'git %s\\n' "$*" >>"$CALL_LOG"
case "$1" in
  diff) exit 1 ;;
  rev-parse) case "$2" in HEAD) echo base ;; *) echo base ;; esac ;;
esac
if [ "$1" = "ls-remote" ] || [ "$1" = "push" ]; then
  [ "$GIT_CONFIG_COUNT" = 2 ] || exit 11
  [ "$GIT_CONFIG_KEY_0" = "$GIT_CONFIG_KEY_1" ] || exit 12
  [ -z "$GIT_CONFIG_VALUE_0" ] || exit 13
  case "$GIT_CONFIG_VALUE_1" in *"AUTHORIZATION: basic "*) ;; *) exit 14 ;; esac
fi
if [ "$1" = "ls-remote" ]; then exit 0; fi
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
if url.endswith("/pulls"):
    body = {"number": 47}
elif "/pulls?state=open" in url:
    body = []
elif url.endswith("/pulls/47"):
    body = {"mergeable": True, "head": {"sha": os.environ["TEST_HEAD"]},
            "base": {"sha": os.environ["TEST_BASE"]}, "merge_base": os.environ["TEST_BASE"]}
elif url.endswith("/merge"):
    body = {}
    open(os.environ["CALL_LOG"], "a").write("merge\\n")
else:
    raise AssertionError(url)
out = args[args.index("-o") + 1]
pathlib.Path(out).write_text(json.dumps(body))
if "-w" in args:
    print("201")
''',
        )
        self.write_executable(
            bindir / "python3",
            '''#!/bin/sh
if [ "$1" = "SCRIPT" ]; then
  printf 'status %s\\n' "$*" >>"$CALL_LOG"
  exit "$STATUS_RESULT"
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
                "FORGEJO_TOKEN": TOKEN,
                "FORGEJO_URL": "https://forgejo.invalid",
                "FORGEJO_OWNER": "fixture",
                "FORGEJO_REPO": "config",
                "BASE_BRANCH": "dev",
                "UPDATE_BRANCH": "update/dms-plugins-lock",
                "REVISION": "abc123",
                "VERSION": "1.2.3",
                "TEST_HEAD": HEAD,
                "TEST_BASE": BASE,
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "http.https://forgejo.invalid/.extraheader",
                "GIT_CONFIG_VALUE_0": "AUTHORIZATION: basic dummy-inherited-header",
            }
        )

    @staticmethod
    def write_executable(path, content):
        path.write_text(content)
        path.chmod(0o700)

    def run_publisher(self, status_result):
        self.env["STATUS_RESULT"] = str(status_result)
        return subprocess.run(
            ["bash", str(PUBLISHER)], cwd=self.root, env=self.env, text=True, capture_output=True
        )

    def test_missing_status_leaves_created_pr_open_without_token_arguments(self):
        result = self.run_publisher(1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("leaving it open", result.stderr)
        calls = self.calls.read_text()
        self.assertNotIn("merge", calls)
        self.assertIn(f"--sha {HEAD}", calls)
        self.assertIn("Validate configurations / Validate candidate (pull_request)", calls)
        self.assertNotIn(TOKEN, calls)
        self.assertNotIn(ENCODED_AUTH, calls)
        self.assertNotIn(TOKEN, result.stdout + result.stderr)

    def test_successful_exact_status_allows_merge(self):
        result = self.run_publisher(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("merge", self.calls.read_text())
        self.assertNotIn(TOKEN, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
