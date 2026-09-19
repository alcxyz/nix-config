#!/usr/bin/env python3
"""Exercise exact receipt reads and credential-safe status publication."""

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[2]
CLIENT = ROOT / "scripts/forgejo/commit-status.py"
SHA = "1" * 40
SECRET = "synthetic-status-secret"


class FixtureHandler(BaseHTTPRequestHandler):
    statuses = []
    requests = []
    redirect = None

    def log_message(self, *_args):
        pass

    def do_GET(self):
        type(self).requests.append(("GET", self.path, self.headers.get("Authorization")))
        body = json.dumps({"statuses": type(self).statuses}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        type(self).requests.append(("POST", self.path, self.headers.get("Authorization")))
        if type(self).redirect:
            self.send_response(302)
            self.send_header("Location", type(self).redirect)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", "0"))
        json.loads(self.rfile.read(length))
        body = b"{}"
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class CommitStatusClient(unittest.TestCase):
    def setUp(self):
        FixtureHandler.statuses = []
        FixtureHandler.requests = []
        FixtureHandler.redirect = None
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        token = Path(self.temporary.name) / "token"
        token.write_text(SECRET + "\n")
        token.chmod(0o600)
        self.token_link = Path(self.temporary.name) / "activated-token"
        self.token_link.symlink_to(token)

    def run_client(self, command, *extra):
        return subprocess.run(
            [
                "python3",
                str(CLIENT),
                command,
                "--url",
                self.url,
                "--owner",
                "fixture",
                "--repo",
                "config",
                "--sha",
                SHA,
                "--context",
                "ci/local-configurations",
                *extra,
            ],
            text=True,
            capture_output=True,
        )

    def test_require_rejects_missing_and_newer_failure_and_uses_exact_sha(self):
        result = self.run_client("require")
        self.assertNotEqual(result.returncode, 0)
        FixtureHandler.statuses = [
            {"id": 1, "context": "ci/local-configurations", "status": "success"},
            {"id": 2, "context": "ci/local-configurations", "status": "failure"},
        ]
        result = self.run_client("require")
        self.assertNotEqual(result.returncode, 0)
        FixtureHandler.statuses.append(
            {"id": 3, "context": "ci/local-configurations", "status": "success"}
        )
        result = self.run_client("require")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(
            all(request[1] == f"/api/v1/repos/fixture/config/commits/{SHA}/status" for request in FixtureHandler.requests)
        )

    def test_publish_reads_activated_symlink_without_logging_credential(self):
        result = self.run_client(
            "publish",
            "--token-file",
            str(self.token_link),
            "--state",
            "success",
            "--description",
            "fixture passed",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        self.assertEqual(FixtureHandler.requests[-1][2], f"token {SECRET}")
        self.assertEqual(
            FixtureHandler.requests[-1][1], f"/api/v1/repos/fixture/config/statuses/{SHA}"
        )

    def test_publish_does_not_follow_redirect_with_credential(self):
        target_requests = []

        class TargetHandler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                target_requests.append(self.headers.get("Authorization"))

            def do_POST(self):
                target_requests.append(self.headers.get("Authorization"))

        target = ThreadingHTTPServer(("127.0.0.1", 0), TargetHandler)
        target_thread = threading.Thread(target=target.serve_forever, daemon=True)
        target_thread.start()
        self.addCleanup(target.server_close)
        self.addCleanup(target.shutdown)
        FixtureHandler.redirect = f"http://127.0.0.1:{target.server_port}/redirected"
        result = self.run_client(
            "publish",
            "--token-file",
            str(self.token_link),
            "--state",
            "success",
            "--description",
            "fixture passed",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        self.assertEqual(target_requests, [])


if __name__ == "__main__":
    unittest.main()
