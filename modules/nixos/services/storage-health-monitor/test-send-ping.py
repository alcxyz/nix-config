#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("ping", Path(__file__).with_name("send-ping.py"))
ping = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ping)


class PingTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.endpoint = Path(self.directory.name) / "endpoint"
        self.endpoint.write_text("https://health.invalid/ping/synthetic-capability\n")
        self.report = Path(self.directory.name) / "report"
        self.report.write_text("synthetic capacity report\n")

    def test_direct_and_project_endpoint_suffixes_use_stdin_only(self):
        for mode in ("base", "check"):
            for suffix in ("", "/start", "/fail"):
                with self.subTest(mode=mode, suffix=suffix):
                    calls = []
                    def run(args, **kwargs):
                        calls.append((args, kwargs))
                        return subprocess.CompletedProcess(args, 0, b"200", b"")
                    ping.send(mode, self.endpoint, "storage-fixture", suffix, self.report, run)
                    args, kwargs = calls[0]
                    config = {key: json.loads(value) for key, value in
                              (line.split(" = ", 1) for line in kwargs["input"].decode().splitlines())}
                    expected = "https://health.invalid/ping/synthetic-capability"
                    if mode == "base":
                        expected += "/storage-fixture"
                    expected += suffix + ("?create=1" if mode == "base" else "")
                    self.assertEqual(config["url"], expected)
                    self.assertEqual(config["data-binary"], "@" + str(self.report))
                    self.assertNotIn(expected, args)
                    self.assertNotIn(self.report.read_text(), args)
                    self.assertEqual(args[args.index("--user-agent") + 1], "storage-health-monitor/1")

    def test_invalid_endpoints_fail_before_transport(self):
        for endpoint in ("", "http://health.invalid/key", "https://user:key@health.invalid",
                         "https://health.invalid/key?query=1", "https://health.invalid/key#fragment",
                         "https://health.invalid/key?", "https://health.invalid/key#",
                         "https://health.invalid/key\ninjected", 'https://health.invalid/key"',
                         "https://health.invalid/key" + chr(92), "https://health.invalid/key" + chr(0)):
            self.endpoint.write_text(endpoint)
            with self.subTest(endpoint=endpoint), self.assertRaises(ValueError):
                ping.send("check", self.endpoint, "storage-fixture", "", self.report,
                          lambda *args, **kwargs: self.fail("unexpected transport"))

    def test_transport_error_output_does_not_disclose_capability(self):
        result = subprocess.CompletedProcess([], 22, b"synthetic-capability", b"synthetic-capability")
        output, error = io.StringIO(), io.StringIO()
        with patch.object(ping.subprocess, "run", return_value=result), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            status = ping.main(["check", str(self.endpoint), "storage-fixture", "", str(self.report)])
        self.assertEqual(status, 1)
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(error.getvalue(), "storage health heartbeat failed\n")

    def test_redirects_are_rejected_without_following(self):
        def run(args, **kwargs):
            self.assertEqual(args[:2], ["curl", "--disable"])
            self.assertNotIn("--location", args)
            self.assertNotIn("-L", args)
            return subprocess.CompletedProcess(args, 0, b"302", b"")
        with self.assertRaises(RuntimeError):
            ping.send("check", self.endpoint, "storage-fixture", "", self.report, run)

    def test_one_total_budget_preserves_response_and_native_fallback(self):
        def run(args, **kwargs):
            self.assertEqual(args[args.index("--max-time") + 1], "10")
            self.assertNotIn("--connect-timeout", args)
            self.assertNotIn("--ipv4", args)
            self.assertNotIn("--ipv6", args)
            return subprocess.CompletedProcess(args, 0, b"204", b"")
        ping.send("check", self.endpoint, "storage-fixture", "", self.report, run)


if __name__ == "__main__":
    unittest.main()
