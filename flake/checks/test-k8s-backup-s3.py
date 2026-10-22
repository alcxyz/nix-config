"""Exercise the evaluated mirror script with real rclone and synthetic S3 only."""

import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit
from xml.sax.saxutils import escape

SCRIPT = Path(sys.argv.pop(1)).read_text()
RCLONE = shutil.which("rclone")
ACCESS = "synthetic-access"
SECRET = "synthetic-secret/+="
KEY = 'nested/object with spaces "quoted"\n'
STAMP = "2026-01-01T00:00:00.000Z"
SYSTEM_HEADERS = {
    "content-type",
    "content-encoding",
    "cache-control",
    "content-disposition",
    "content-language",
}


class Store(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, objects):
        super().__init__(("127.0.0.1", 0), Handler)
        self.objects = objects.copy()
        self.object_headers = {}
        self.buckets = ["fixture"]
        self.requests = []
        self.hide = False
        self.fail_listing = None
        self.fail_put = False
        self.put_failures = 0
        self.growing = False
        self.listings = 0

    @property
    def endpoint(self):
        return f"http://127.0.0.1:{self.server_port}"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, status=200, body=b"", **headers):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        for key, value in headers.items():
            self.send_header(key.replace("_", "-"), value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def handle_request(self):
        request = urlsplit(self.path)
        path = unquote(request.path).lstrip("/")
        bucket, _, key = path.partition("/")
        query = parse_qs(request.query, keep_blank_values=True)
        store = self.server
        store.requests.append((self.command, path))
        # Require the synthetic file-provided access key to reach the client.
        if ACCESS not in self.headers.get("Authorization", ""):
            self.reply(403)
            return
        if self.command == "GET" and not key:
            if store.fail_listing == ("objects" if bucket else "buckets"):
                self.reply(403, b"<Error><Code>AccessDenied</Code></Error>")
                return
            if not bucket:
                buckets = "".join(
                    f"<Bucket><Name>{b}</Name><CreationDate>{STAMP}</CreationDate></Bucket>"
                    for b in store.buckets
                )
                body = f"<ListAllMyBucketsResult><Buckets>{buckets}</Buckets></ListAllMyBucketsResult>"
            else:
                store.listings += 1
                prefix = query.get("prefix", [""])[0]
                objects = [] if store.hide else sorted(store.objects.items())
                objects = [(k, v) for k, v in objects if k.startswith(prefix)]
                delimiter = query.get("delimiter", [""])[0]
                prefixes = set()
                if delimiter:
                    for k, _ in objects:
                        suffix = k[len(prefix) :]
                        if delimiter in suffix:
                            prefixes.add(
                                prefix + suffix.split(delimiter)[0] + delimiter
                            )
                    objects = [
                        (k, v) for k, v in objects if delimiter not in k[len(prefix) :]
                    ]
                common_prefixes = "".join(
                    f"<CommonPrefixes><Prefix>{escape(p)}</Prefix></CommonPrefixes>"
                    for p in sorted(prefixes)
                )
                contents = "".join(
                    f"<Contents><Key>{escape(k)}</Key><LastModified>{STAMP}</LastModified>"
                    f'<ETag>"{hashlib.md5(v).hexdigest()}"</ETag><Size>{len(v)}</Size></Contents>'
                    for k, v in objects
                    if k.startswith(prefix)
                )
                body = (
                    f"<ListBucketResult><Name>{bucket}</Name><Prefix>{escape(prefix)}</Prefix>"
                    f"<IsTruncated>false</IsTruncated>{common_prefixes}{contents}</ListBucketResult>"
                )
                if store.growing:
                    # New source objects after each listing must not prevent
                    # verification of the finite checkpoint captured earlier.
                    store.objects[f"new-{store.listings}"] = b"new"
            self.reply(body=body.encode(), Content_Type="application/xml")
        elif self.command == "HEAD":
            if key in store.objects:
                data = store.objects[key]
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("ETag", f'"{hashlib.md5(data).hexdigest()}"')
                self.send_header("Last-Modified", "Thu, 01 Jan 2026 00:00:00 GMT")
                for name, value in store.object_headers.get(key, {}).items():
                    self.send_header(name, value)
                self.end_headers()
            else:
                self.reply(404 if key else 200)
        elif self.command == "GET" and key in store.objects:
            self.reply(body=store.objects[key], **store.object_headers.get(key, {}))
        elif self.command == "PUT":
            data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if key and (store.fail_put or store.put_failures > 0):
                store.put_failures = max(0, store.put_failures - 1)
                self.reply(403, b"<Error><Code>AccessDenied</Code></Error>")
            else:
                if key:
                    store.objects[key] = data
                    store.object_headers[key] = {
                        name.lower(): value
                        for name, value in self.headers.items()
                        if name.lower().startswith("x-amz-meta-")
                        or name.lower() in SYSTEM_HEADERS
                    }
                self.reply(ETag=f'"{hashlib.md5(data).hexdigest()}"')
        elif self.command == "DELETE":
            store.objects.pop(key, None)
            store.object_headers.pop(key, None)
            self.reply(204)
        else:
            self.reply(404)

    do_GET = handle_request
    do_HEAD = handle_request
    do_PUT = handle_request
    do_DELETE = handle_request


class MirrorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = Store({KEY: b"checkpoint"})
        self.replica = Store({"obsolete": b"delete me"})
        for store in (self.source, self.replica):
            threading.Thread(target=store.serve_forever, daemon=True).start()
            self.addCleanup(store.server_close)
            self.addCleanup(store.shutdown)
        credentials = self.root / "credentials"
        credentials.mkdir()
        (credentials / "s3_access_key").write_text(ACCESS + "\n")
        (credentials / "s3_secret_key").write_text(SECRET + "\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Record argv and check credential delivery internally, without dumping
        # process environments. Only these synthetic fixture values are used.
        (self.bin / "rclone").write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            f"assert os.environ['RCLONE_S3_ACCESS_KEY_ID'] == {ACCESS!r}\n"
            f"assert os.environ['RCLONE_S3_SECRET_ACCESS_KEY'] == {SECRET!r}\n"
            f"with open({str(self.root / 'calls')!r}, 'a') as f:\n"
            "    f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            f"os.execv({RCLONE!r}, [{RCLONE!r}] + sys.argv[1:])\n"
        )
        (self.bin / "rclone").chmod(0o755)
        (self.bin / "sleep").write_text("#!/bin/sh\nexit 0\n")
        (self.bin / "sleep").chmod(0o755)
        self.env = {
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "HOME": str(self.root),
            "TMPDIR": str(self.root),
            "CREDENTIALS_DIRECTORY": str(credentials),
        }

    def run_mirror(self, *, success=True, stat_size=None):
        script = SCRIPT.replace("http://192.0.2.11:9000", self.source.endpoint)
        script = script.replace("http://192.0.2.10:9000", self.replica.endpoint)
        if stat_size is not None:
            # Keep the actual rclone stat request independent, then inject a
            # misleading response to exercise verification's refusal paths.
            wrapper = self.bin / "rclone"
            text = wrapper.read_text().replace(
                "import json, os, sys", "import json, os, sys, subprocess"
            )
            marker = f"os.execv({RCLONE!r}, [{RCLONE!r}] + sys.argv[1:])"
            text = text.replace(
                marker,
                (
                    "if '--stat' in sys.argv:\n"
                    f"    result = subprocess.run([{RCLONE!r}] + sys.argv[1:], capture_output=True)\n"
                    "    if result.returncode: sys.exit(result.returncode)\n"
                    "    item = json.loads(result.stdout)\n"
                    f"    item.update({stat_size!r})\n"
                    "    print(json.dumps(item))\n"
                    "    sys.exit(0)\n" + marker
                ),
            )
            wrapper.write_text(text)
        result = subprocess.run(
            ["bash", "-c", script],
            env=self.env,
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        calls = [
            json.loads(line) for line in (self.root / "calls").read_text().splitlines()
        ]
        for value in (ACCESS, SECRET):
            self.assertNotIn(value, result.stdout + result.stderr + json.dumps(calls))
        self.assertFalse(
            list(self.root.glob("tmp.*")), "ephemeral configuration leaked"
        )
        syncs = [call for call in calls if "sync" in call]
        self.assertLessEqual(len(syncs), 5)
        for call in syncs:
            self.assertEqual(call[-2:], ["source:fixture", "replica:fixture"])
            self.assertIn("--delete-after", call)
            self.assertIn("--metadata", call)
            self.assertIn("--no-unicode-normalization", call)
            for flag, value in {
                "--retries": "3",
                "--low-level-retries": "10",
                "--transfers": "4",
                "--checkers": "4",
                "--s3-upload-concurrency": "1",
                "--multi-thread-streams": "0",
            }.items():
                self.assertEqual(call[call.index(flag) + 1], value)
        return result, syncs

    def test_sync_deletes_and_preserves_finite_checkpoint(self):
        self.source.growing = True
        result, syncs = self.run_mirror()
        self.assertEqual(len(syncs), 1)
        self.assertEqual(self.replica.objects[KEY], b"checkpoint")
        self.assertNotIn("obsolete", self.replica.objects)
        self.assertGreater(len(self.source.objects), len(self.replica.objects))
        self.assertIn("checkpoint_objects=1", result.stdout)

    def test_object_metadata_and_restoration_headers_survive(self):
        self.source.objects = {
            "compressed-snapshot": gzip.compress(b"synthetic backup", mtime=0),
            "manifest": b'{"format":"fixture"}',
        }
        self.source.object_headers = {
            "compressed-snapshot": {
                "content-type": "application/x-fixture-backup",
                "content-encoding": "gzip",
                "cache-control": "no-transform",
                "content-disposition": 'attachment; filename="snapshot.gz"',
                "x-amz-meta-backup-format": "fixture-compressed-v1",
                "x-amz-meta-backup-id": "snapshot-1",
            },
            "manifest": {
                "content-type": "application/x-fixture-manifest+json",
                "content-language": "en",
                "x-amz-meta-backup-format": "fixture-manifest-v2",
                "x-amz-meta-backup-id": "manifest-2",
            },
        }
        self.run_mirror()
        self.assertEqual(self.replica.objects, self.source.objects)
        for key, headers in self.source.object_headers.items():
            for name, value in headers.items():
                self.assertEqual(
                    self.replica.object_headers[key].get(name), value, (key, name)
                )
        self.assertNotIn("content-encoding", self.replica.object_headers["manifest"])

    def test_distinct_unicode_keys_survive(self):
        self.source.objects = {"caf\u00e9": b"NFC", "cafe\u0301": b"NFD"}
        result, syncs = self.run_mirror()
        self.assertEqual(len(syncs), 1)
        self.assertEqual(self.replica.objects, self.source.objects)
        self.assertIn("checkpoint_objects=2", result.stdout)

    def test_listing_gap_uses_exact_head_for_key_with_newline(self):
        self.replica.hide = True
        result, _ = self.run_mirror()
        self.assertIn(("HEAD", "fixture/" + KEY), self.replica.requests)
        self.assertIn("direct_stat_objects=1", result.stdout)

    def test_wrong_stat_size_is_not_verified(self):
        self.replica.hide = True
        result, syncs = self.run_mirror(success=False, stat_size={"Size": 999})
        self.assertEqual(len(syncs), 5)
        self.assertIn("replica verification failed", result.stderr)

    def test_directory_stat_is_not_verified(self):
        self.replica.hide = True
        _, syncs = self.run_mirror(success=False, stat_size={"IsDir": True, "Size": 10})
        self.assertEqual(len(syncs), 5)

    def test_failed_source_bucket_listing_cannot_start_sync(self):
        self.source.fail_listing = "buckets"
        _, syncs = self.run_mirror(success=False)
        self.assertFalse(syncs)
        self.assertEqual(self.replica.objects, {"obsolete": b"delete me"})

    def test_partial_failed_bucket_listing_cannot_start_sync(self):
        wrapper = self.bin / "rclone"
        marker = f"os.execv({RCLONE!r}, [{RCLONE!r}] + sys.argv[1:])"
        wrapper.write_text(
            wrapper.read_text().replace(
                marker,
                (
                    "if sys.argv[-1] == 'source:':\n"
                    "    print(json.dumps([{'IsDir': True, 'Path': 'fixture'}]))\n"
                    "    sys.exit(7)\n" + marker
                ),
            )
        )
        _, syncs = self.run_mirror(success=False)
        self.assertFalse(syncs)
        self.assertEqual(self.replica.objects, {"obsolete": b"delete me"})

    def test_failed_inventory_cannot_start_sync(self):
        self.source.fail_listing = "objects"
        _, syncs = self.run_mirror(success=False)
        self.assertFalse(syncs)

    def test_failed_replica_inventory_cannot_report_verified(self):
        self.replica.fail_listing = "objects"
        result, _ = self.run_mirror(success=False)
        self.assertNotIn("verified bucket", result.stdout)

    def test_no_buckets_refuses_sync(self):
        self.source.buckets.clear()
        _, syncs = self.run_mirror(success=False)
        self.assertFalse(syncs)

    def test_empty_bucket_deletes_stale_objects_and_verifies_zero_checkpoint(self):
        self.source.objects.clear()
        result, syncs = self.run_mirror()
        self.assertEqual(len(syncs), 1)
        self.assertEqual(self.replica.objects, {})
        self.assertIn("checkpoint_objects=0", result.stdout)
        self.assertIn("checkpoint_bytes=0", result.stdout)

    def test_upload_failure_retries_and_recovers(self):
        self.replica.put_failures = 1
        self.run_mirror()
        self.assertEqual(self.replica.objects[KEY], b"checkpoint")
        self.assertNotIn("obsolete", self.replica.objects)

    def test_sync_failure_is_bounded(self):
        self.replica.fail_put = True
        result, syncs = self.run_mirror(success=False)
        self.assertEqual(len(syncs), 5)
        self.assertIn("mirror failed", result.stderr)
        self.assertIn("obsolete", self.replica.objects)


if __name__ == "__main__":
    unittest.main()
