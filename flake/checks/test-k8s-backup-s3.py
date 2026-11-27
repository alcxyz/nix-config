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
import time
import unittest
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit
from xml.sax.saxutils import escape

SCRIPT = Path(sys.argv.pop(1)).read_text()
SNAPSHOT_SCRIPT = Path(sys.argv.pop(1)).read_text()
INCREMENTAL_SCRIPT = Path(sys.argv.pop(1)).read_text()
STORAGE_SCRIPT = Path(sys.argv.pop(1)).read_text()
LOCAL_BACKUP_SCRIPT = Path(sys.argv.pop(1)).read_text()
SPLIT_SCRIPT = Path(sys.argv.pop(1)).read_text()
SPLIT_BASE_INCREMENTAL_SCRIPT = Path(sys.argv.pop(1)).read_text()
SPLIT_INCREMENTAL_SCRIPT = Path(sys.argv.pop(1)).read_text()
SNAPSHOT_PROPERTY = "org.nix-config:k8s-backup-s3-mirror"
DATASET = "fixture/k8s-backups"
RCLONE = shutil.which("rclone")
ACCESS = "synthetic-access"
SECRET = "synthetic-secret/+="
EXTRA_ACCESS = "synthetic-extra-access"
EXTRA_SECRET = "synthetic-extra-secret/+="
KEY = 'nested/object with spaces "quoted"\n'
STAMP = "2026-01-01T00:00:00.000Z"
SYSTEM_HEADERS = {
    "content-type",
    "content-encoding",
    "cache-control",
    "content-disposition",
    "content-language",
}


def initialized_marker(remote, endpoint, bucket):
    """The mirror's record that a full pass verified this bucket under this
    assignment: a directory per bucket, a marker per remote and endpoint."""
    directory = hashlib.sha256(bucket.encode()).hexdigest()
    name = hashlib.sha256(f"{remote}\n{endpoint}\n{bucket}".encode()).hexdigest()
    return Path(directory) / name


class Store(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, objects):
        super().__init__(("127.0.0.1", 0), Handler)
        self.objects = objects.copy()
        self.object_headers = {}
        self.modified = {}
        self.drop_puts = False
        self.growing_recent = False
        self.bucket_objects = {}
        self.bucket_object_headers = {}
        self.buckets = ["fixture"]
        self.requests = []
        self.hide = False
        self.fail_listing = None
        self.fail_put = False
        self.fail_buckets = set()
        self.put_failures = 0
        self.growing = False
        self.listings = 0
        self.access = ACCESS

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
        bucket_objects = (
            store.objects
            if bucket == "fixture"
            else store.bucket_objects.setdefault(bucket, {})
        )
        bucket_headers = (
            store.object_headers
            if bucket == "fixture"
            else store.bucket_object_headers.setdefault(bucket, {})
        )
        # Require the synthetic file-provided access key to reach the client.
        if f"Credential={store.access}/" not in self.headers.get("Authorization", ""):
            self.reply(403)
            return
        if self.command == "GET" and not key:
            if bucket in store.fail_buckets or store.fail_listing == (
                "objects" if bucket else "buckets"
            ):
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
                objects = [] if store.hide else sorted(bucket_objects.items())
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
                    f"<Contents><Key>{escape(k)}</Key><LastModified>{store.modified.get(k, STAMP)}</LastModified>"
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
                    bucket_objects[f"new-{store.listings}"] = b"new"
                    if store.growing_recent:
                        store.modified[f"new-{store.listings}"] = datetime.now(
                            timezone.utc
                        ).strftime("%Y-%m-%dT%H:%M:%S.000Z")
            self.reply(body=body.encode(), Content_Type="application/xml")
        elif self.command == "HEAD":
            if key in bucket_objects:
                data = bucket_objects[key]
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("ETag", f'"{hashlib.md5(data).hexdigest()}"')
                self.send_header("Last-Modified", "Thu, 01 Jan 2026 00:00:00 GMT")
                for name, value in bucket_headers.get(key, {}).items():
                    self.send_header(name, value)
                self.end_headers()
            else:
                self.reply(404 if key else 200)
        elif self.command == "GET" and key in bucket_objects:
            self.reply(body=bucket_objects[key], **bucket_headers.get(key, {}))
        elif self.command == "PUT" and key and self.headers.get("x-amz-copy-source"):
            # CopyObject, which rclone uses to update a replica object's
            # modification time in place: keep the source's bytes.
            copied_bucket, _, copied_key = (
                unquote(self.headers["x-amz-copy-source"]).lstrip("/").partition("/")
            )
            copied_objects = (
                store.objects
                if copied_bucket == "fixture"
                else store.bucket_objects.setdefault(copied_bucket, {})
            )
            if copied_key not in copied_objects:
                self.reply(404, b"<Error><Code>NoSuchKey</Code></Error>")
                return
            data = copied_objects[copied_key]
            bucket_objects[key] = data
            body = (
                f'<CopyObjectResult><LastModified>{STAMP}</LastModified>'
                f'<ETag>"{hashlib.md5(data).hexdigest()}"</ETag></CopyObjectResult>'
            )
            self.reply(body=body.encode(), Content_Type="application/xml")
        elif self.command == "PUT":
            data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if key and (store.fail_put or store.put_failures > 0):
                store.put_failures = max(0, store.put_failures - 1)
                self.reply(403, b"<Error><Code>AccessDenied</Code></Error>")
            else:
                if key and not store.drop_puts:
                    bucket_objects[key] = data
                    bucket_headers[key] = {
                        name.lower(): value
                        for name, value in self.headers.items()
                        if name.lower().startswith("x-amz-meta-")
                        or name.lower() in SYSTEM_HEADERS
                    }
                self.reply(ETag=f'"{hashlib.md5(data).hexdigest()}"')
        elif self.command == "DELETE":
            bucket_objects.pop(key, None)
            bucket_headers.pop(key, None)
            self.reply(204)
        else:
            self.reply(404)

    do_GET = handle_request
    do_HEAD = handle_request
    do_PUT = handle_request
    do_DELETE = handle_request


class MirrorTests(unittest.TestCase):
    script = SCRIPT
    snapshots_enabled = False

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
            f"assert os.environ['RCLONE_CONFIG_SOURCE_ACCESS_KEY_ID'] == {ACCESS!r}\n"
            f"assert os.environ['RCLONE_CONFIG_SOURCE_SECRET_ACCESS_KEY'] == {SECRET!r}\n"
            f"assert os.environ['RCLONE_CONFIG_REPLICA_ACCESS_KEY_ID'] == {ACCESS!r}\n"
            f"assert os.environ['RCLONE_CONFIG_REPLICA_SECRET_ACCESS_KEY'] == {SECRET!r}\n"
            "assert 'RCLONE_S3_ACCESS_KEY_ID' not in os.environ\n"
            f"with open({str(self.root / 'calls')!r}, 'a') as f:\n"
            "    f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            f"with open({str(self.root / 'events')!r}, 'a') as f:\n"
            "    f.write(json.dumps(['rclone'] + sys.argv[1:]) + '\\n')\n"
            f"os.execv({RCLONE!r}, [{RCLONE!r}] + sys.argv[1:])\n"
        )
        (self.bin / "rclone").chmod(0o755)
        (self.bin / "sleep").write_text("#!/bin/sh\nexit 0\n")
        (self.bin / "sleep").chmod(0o755)
        self.snapshots = self.root / "snapshots.json"
        self.snapshots.write_text("[]")
        # Never allow these tests to reach the host's ZFS command.
        (self.bin / "zfs").write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            f"state = {str(self.snapshots)!r}\n"
            f"dataset = {DATASET!r}\n"
            f"prop = {SNAPSHOT_PROPERTY!r}\n"
            "args = sys.argv[1:]\n"
            f"with open({str(self.root / 'events')!r}, 'a') as f:\n"
            "    f.write(json.dumps(['zfs'] + args) + '\\n')\n"
            "if os.environ.get('ZFS_FAILURE') == args[0]: sys.exit(9)\n"
            "with open(state) as f: snapshots = json.load(f)\n"
            "if args[0] == 'snapshot':\n"
            "    assert args[1:3] == ['-o', prop + '=verified'], args\n"
            "    assert args[3] == '-o' and args[4].startswith(prop + '-scope='), args\n"
            "    assert args[5].startswith(dataset + '@k8s-backup-s3-mirror-'), args\n"
            "    snapshots.append({'name': args[5], 'value': 'verified', 'source': 'local'})\n"
            "    print('created verified mirror snapshot')\n"
            "elif args[0] == 'list':\n"
            "    assert args[1:] == ['-H', '-t', 'snapshot', '-o', 'name', '-s', 'creation', '-s', 'name', '-d', '1', dataset], args\n"
            "    for item in snapshots: print(item['name'])\n"
            "elif args[0] == 'get':\n"
            "    assert args[1:5] == ['-H', '-o', 'value,source', prop], args\n"
            "    item = next(item for item in snapshots if item['name'] == args[5])\n"
            "    print(item['value'] + '\t' + item['source'])\n"
            "elif args[0] == 'destroy':\n"
            "    assert len(args) == 2, args\n"
            "    item = next(item for item in snapshots if item['name'] == args[1])\n"
            "    assert item['value'] == 'verified' and item['source'] == 'local', args\n"
            "    snapshots.remove(item)\n"
            "else: raise AssertionError(args)\n"
            "with open(state, 'w') as f: json.dump(snapshots, f)\n"
        )
        (self.bin / "zfs").chmod(0o755)
        # Only the weekday is faked; ages come from the real clock.
        (self.bin / "date").write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "+%a" ] && [ -n "$FAKE_WEEKDAY" ]; then\n'
            '  echo "$FAKE_WEEKDAY"\n'
            "  exit 0\n"
            "fi\n"
            f'exec {shutil.which("date")} "$@"\n'
        )
        (self.bin / "date").chmod(0o755)
        self.state = self.root / "state"
        self.state.mkdir()
        self.env = {
            "STATE_DIRECTORY": str(self.state),
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "HOME": str(self.root),
            "TMPDIR": str(self.root),
            "CREDENTIALS_DIRECTORY": str(credentials),
        }

    def run_mirror(self, *, success=True, stat_size=None, zfs_failure=None):
        if zfs_failure:
            self.env["ZFS_FAILURE"] = zfs_failure
        # Each assertion below is about this run alone.
        for name in ("calls", "events"):
            (self.root / name).write_text("")
        script = self.script.replace("http://192.0.2.11:9000", self.source.endpoint)
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
        events = [
            json.loads(line) for line in (self.root / "events").read_text().splitlines()
        ]
        zfs_calls = [event[1:] for event in events if event[0] == "zfs"]
        if not self.snapshots_enabled or (not success and not zfs_failure):
            self.assertEqual(zfs_calls, [], events)
        elif success:
            self.assertEqual(zfs_calls[0][0], "snapshot")
            self.assertEqual(sum(call[0] == "snapshot" for call in zfs_calls), 1)
            self.assertLess(
                max(i for i, event in enumerate(events) if event[0] == "rclone"),
                next(i for i, event in enumerate(events) if event[0] == "zfs"),
            )
        for value in (ACCESS, SECRET):
            self.assertNotIn(value, result.stdout + result.stderr + json.dumps(calls))
        self.assertFalse(
            list(self.root.glob("tmp.*")), "ephemeral configuration leaked"
        )
        syncs = [call for call in calls if "sync" in call]
        self.assertLessEqual(len(syncs), 5 * len(self.source.buckets))
        for call in syncs:
            bucket = call[-2].split(":", 1)[1]
            self.assertIn(bucket, self.source.buckets)
            self.assertEqual(call[-2:], [f"source:{bucket}", f"replica:{bucket}"])
            self.assertEqual("--checksum" in call, bucket == "fixture")
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

    def test_sync_replaces_same_size_object_with_different_content(self):
        self.replica.objects[KEY] = b"CHECKPOINT"
        self.run_mirror()
        self.assertEqual(self.replica.objects[KEY], b"checkpoint")

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


class SnapshotTests(MirrorTests):
    # Run the entire real-rclone failure suite with snapshots enabled too.
    script = SNAPSHOT_SCRIPT
    snapshots_enabled = True

    def seed_snapshots(self):
        snapshots = [
            # Name ordering differs from creation ordering (the fixture order).
            {"name": DATASET + "@z-old-owned", "value": "verified", "source": "local"},
            {"name": DATASET + "@keep-manual", "value": "-", "source": "-"},
            {
                "name": DATASET + "@a-newer-owned",
                "value": "verified",
                "source": "local",
            },
            {
                "name": DATASET + "@keep-other-value",
                "value": "other",
                "source": "local",
            },
            {
                "name": DATASET + "@keep-inherited",
                "value": "verified",
                "source": "inherited from fixture",
            },
            {
                "name": DATASET + "@keep-received",
                "value": "verified",
                "source": "received",
            },
            {
                "name": DATASET + "@k8s-backup-s3-mirror-unmarked",
                "value": "-",
                "source": "-",
            },
            {
                "name": DATASET + "/child@keep-owned",
                "value": "verified",
                "source": "local",
            },
        ]
        self.snapshots.write_text(json.dumps(snapshots))
        return snapshots

    def test_only_listed_buckets_compare_checksums(self):
        self.source.buckets.append("second")
        _, syncs = self.run_mirror()
        checksum = {call[-2]: "--checksum" in call for call in syncs}
        self.assertEqual(checksum, {"source:fixture": True, "source:second": False})

    def test_all_buckets_verify_before_single_snapshot(self):
        self.source.buckets.append("second")
        result, syncs = self.run_mirror()
        self.assertEqual(len(syncs), 2)
        marker = result.stdout.index("created verified mirror snapshot")
        for bucket in self.source.buckets:
            self.assertLess(result.stdout.index(f"verified bucket={bucket} "), marker)

    def test_later_bucket_failure_cannot_snapshot_partial_pass(self):
        self.source.buckets.append("second")
        self.source.fail_buckets = {"second"}
        result, syncs = self.run_mirror(success=False)
        self.assertEqual(len(syncs), 1)
        self.assertIn("verified bucket=fixture ", result.stdout)

    def test_retention_preserves_unowned_and_keeps_last_two_owned(self):
        before = self.seed_snapshots()
        self.run_mirror()
        after = json.loads(self.snapshots.read_text())
        self.assertEqual(after[:-1], before[1:])
        self.assertEqual(after[-1]["value"], "verified")
        self.assertEqual(after[-1]["source"], "local")

    def test_snapshot_error_fails_without_pruning(self):
        before = self.seed_snapshots()
        self.run_mirror(success=False, zfs_failure="snapshot")
        self.assertEqual(json.loads(self.snapshots.read_text()), before)
        events = [
            json.loads(line) for line in (self.root / "events").read_text().splitlines()
        ]
        self.assertEqual(
            [event[1] for event in events if event[0] == "zfs"], ["snapshot"]
        )

    def test_inventory_error_fails_without_pruning(self):
        before = self.seed_snapshots()
        self.run_mirror(success=False, zfs_failure="list")
        self.assertEqual(json.loads(self.snapshots.read_text())[:-1], before)

    def test_property_error_fails_without_pruning(self):
        before = self.seed_snapshots()
        self.run_mirror(success=False, zfs_failure="get")
        self.assertEqual(json.loads(self.snapshots.read_text())[:-1], before)

    def test_prune_error_fails_service(self):
        before = self.seed_snapshots()
        self.run_mirror(success=False, zfs_failure="destroy")
        self.assertEqual(json.loads(self.snapshots.read_text())[:-1], before)


class IncrementalTests(MirrorTests):
    # Also runs the inherited tests: with no record of a verified pass, a mirror
    # with a full verification day behaves like one without it.
    script = INCREMENTAL_SCRIPT
    snapshots_enabled = True

    def setUp(self):
        super().setUp()
        self.env["FAKE_WEEKDAY"] = "Mon"

    @staticmethod
    def hours_ago(hours):
        moment = datetime.now(timezone.utc) - timedelta(hours=hours)
        return moment.strftime("%Y-%m-%dT%H:%M:%S.000Z")

    def record(self, *, verified=24, full=48, initialized=True):
        self.source.objects["new-block"] = b"recent"
        self.source.modified["new-block"] = self.hours_ago(1)
        if initialized:
            # A full pass has verified every bucket from this source.
            for bucket in self.source.buckets:
                marker = self.state / "initialized" / initialized_marker(
                    "source", self.source.endpoint, bucket)
                marker.parent.mkdir(parents=True, exist_ok=True)
                marker.write_text("")
        now = int(time.time())
        (self.state / "last-verified").write_text(f"{now - verified * 3600}\n")
        (self.state / "last-full").write_text(f"{now - full * 3600}\n")

    def recorded(self, name):
        return int((self.state / name).read_text())

    def snapshot_scopes(self):
        events = [
            json.loads(line) for line in (self.root / "events").read_text().splitlines()
        ]
        return [
            event[5].rsplit("=", 1)[1]
            for event in events
            if event[:2] == ["zfs", "snapshot"]
        ]

    def test_a_bucket_without_a_full_pass_gets_one_inside_an_incremental_pass(self):
        # State from before per-bucket markers, or a bucket new since the last
        # full pass: its older objects must still arrive.
        self.record(initialized=False)
        self.source.objects["old-block"] = b"older than the last verified pass"
        result, syncs = self.run_mirror()
        self.assertIn("mirror pass scope=incremental", result.stdout)
        self.assertIn("bucket=fixture scope=full", result.stdout)
        self.assertEqual(len(syncs), 1)
        self.assertEqual(self.replica.objects["old-block"], b"older than the last verified pass")
        self.assertTrue((self.state / "initialized" / initialized_marker(
            "source", self.source.endpoint, "fixture")).exists())
        self.assertEqual(self.snapshot_scopes(), ["incremental"])
        result, syncs = self.run_mirror()
        self.assertIn("bucket=fixture scope=incremental", result.stdout)
        self.assertEqual(syncs, [])

    def test_incremental_copies_recent_objects_without_listing_replica(self):
        self.record()
        result, syncs = self.run_mirror()
        self.assertEqual(syncs, [])
        self.assertEqual(self.replica.listings, 0)
        self.assertEqual(self.replica.objects["new-block"], b"recent")
        self.assertNotIn(KEY, self.replica.objects)
        self.assertIn("obsolete", self.replica.objects)
        self.assertIn("mirror pass scope=incremental", result.stdout)
        self.assertIn(
            "verified-recent bucket=fixture recent_bytes=6 recent_objects=1",
            result.stdout,
        )
        self.assertEqual(self.snapshot_scopes(), ["incremental"])

    def test_window_starts_at_last_verified_pass(self):
        self.source.objects.update({"in-window": b"a", "before-window": b"b"})
        self.source.modified.update(
            {"in-window": self.hours_ago(70), "before-window": self.hours_ago(80)}
        )
        self.record(verified=72, full=72)
        self.run_mirror()
        self.assertIn("in-window", self.replica.objects)
        self.assertNotIn("before-window", self.replica.objects)

    def test_recent_object_of_same_size_is_replaced(self):
        self.replica.objects["new-block"] = b"RECENT"
        self.record()
        self.run_mirror()
        self.assertEqual(self.replica.objects["new-block"], b"recent")

    def test_lost_object_fails_and_keeps_the_window(self):
        self.record()
        before = self.recorded("last-verified")
        self.replica.drop_puts = True
        result, _ = self.run_mirror(success=False)
        self.assertIn("recent copy failed for bucket fixture", result.stderr)
        self.assertEqual(self.recorded("last-verified"), before)
        self.replica.drop_puts = False
        self.run_mirror()
        self.assertEqual(self.replica.objects["new-block"], b"recent")
        self.assertGreater(self.recorded("last-verified"), before)

    def test_objects_arriving_during_a_pass_do_not_fail_it(self):
        self.record()
        self.source.growing = True
        self.source.growing_recent = True
        result, _ = self.run_mirror()
        self.assertIn("verified-recent bucket=fixture", result.stdout)
        self.assertIn("attempts=1", result.stdout)

    def test_full_pass_does_not_fail_on_objects_arriving_during_recent_copy(self):
        self.record()
        self.env["FAKE_WEEKDAY"] = "Sat"
        self.source.growing = True
        self.source.growing_recent = True
        _, syncs = self.run_mirror()
        self.assertEqual(len(syncs), 1)

    def test_incremental_advances_only_the_verified_record(self):
        self.record()
        verified = self.recorded("last-verified")
        full = self.recorded("last-full")
        self.run_mirror()
        self.assertGreater(self.recorded("last-verified"), verified)
        self.assertEqual(self.recorded("last-full"), full)

    def test_full_day_reconciles_and_counts_what_recent_copy_missed(self):
        self.record()
        self.env["FAKE_WEEKDAY"] = "Sat"
        full = self.recorded("last-full")
        result, syncs = self.run_mirror()
        self.assertEqual(len(syncs), 1)
        self.assertEqual(self.replica.objects[KEY], b"checkpoint")
        self.assertNotIn("obsolete", self.replica.objects)
        self.assertIn("verified-recent bucket=fixture", result.stdout)
        self.assertIn("reconciled_copies=1 reconciled_deletes=1", result.stdout)
        self.assertGreater(self.recorded("last-full"), full)
        self.assertEqual(self.snapshot_scopes(), ["full"])

    def test_missed_full_pass_runs_on_the_next_day(self):
        self.record(full=8 * 24)
        self.env["FAKE_WEEKDAY"] = "Sun"
        _, syncs = self.run_mirror()
        self.assertEqual(len(syncs), 1)

    def test_failed_full_pass_runs_on_the_next_day_after_a_recent_full(self):
        self.record(full=4 * 24)
        self.env["FAKE_WEEKDAY"] = "Sat"
        self.replica.fail_put = True
        self.run_mirror(success=False)
        self.replica.fail_put = False
        self.env["FAKE_WEEKDAY"] = "Sun"
        _, syncs = self.run_mirror()
        self.assertEqual(len(syncs), 1)
        self.env["FAKE_WEEKDAY"] = "Mon"
        _, syncs = self.run_mirror()
        self.assertEqual(syncs, [])

    def test_recent_full_pass_is_not_repeated_on_the_next_day(self):
        self.record(full=24)
        self.env["FAKE_WEEKDAY"] = "Sun"
        _, syncs = self.run_mirror()
        self.assertEqual(syncs, [])

    def test_no_record_runs_in_full(self):
        result, syncs = self.run_mirror()
        self.assertEqual(len(syncs), 1)
        self.assertNotIn("verified-recent", result.stdout)
        self.assertGreater(self.recorded("last-verified"), 0)
        self.assertGreater(self.recorded("last-full"), 0)

    def test_damaged_or_implausible_record_runs_in_full(self):
        future = int(time.time()) + 86400
        for value in ("not a time", "010", "60", str(future), "9" * 30):
            with self.subTest(value=value):
                self.record()
                (self.state / "last-verified").write_text(f"{value}\n")
                _, syncs = self.run_mirror()
                self.assertEqual(len(syncs), 1)

    def test_recovered_sync_error_still_reaches_the_journal(self):
        self.replica.put_failures = 1
        result, _ = self.run_mirror()
        self.assertIn("ERROR", result.stderr)


class StorageTests(unittest.TestCase):
    def run_storage(
        self,
        *,
        readonly="off",
        mounted="yes",
        source=DATASET,
        target="/var/lib/k8s-backup-fixture",
        fs_type="zfs",
        findmnt_status=0,
        property_status=0,
        success=True,
    ):
        # Shell functions model mount identity without inspecting live mounts
        # or writing to a live dataset. Directory creation is only recorded.
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "installed"
            prelude = f"""
zfs() {{
  case "$1" in
    list) return 0 ;;
    set) printf '%s\\n' "$*" ;;
    get)
      [ {property_status} -eq 0 ] || return {property_status}
      case "$5" in
        readonly) printf '%s\\n' {readonly!r} ;;
        mounted) printf '%s\\n' {mounted!r} ;;
        *) return 99 ;;
      esac ;;
    *) return 99 ;;
  esac
}}
findmnt() {{
  [ "$4" = --mountpoint ] && [ "$5" = /var/lib/k8s-backup-fixture ] || return 99
  [ {findmnt_status} -eq 0 ] || return {findmnt_status}
  case "$3" in
    SOURCE) printf '%s\\n' {source!r} ;;
    TARGET) printf '%s\\n' {target!r} ;;
    FSTYPE) printf '%s\\n' {fs_type!r} ;;
    *) return 99 ;;
  esac
}}
install() {{ printf '%s\\n' "$*" > {str(marker)!r}; }}
"""
            result = subprocess.run(
                ["bash", "-c", prelude + STORAGE_SCRIPT],
                text=True,
                capture_output=True,
                timeout=5,
                check=False,
            )
            self.assertEqual(
                result.returncode == 0, success, result.stdout + result.stderr
            )
            self.assertEqual(marker.exists(), success)
            self.assertNotIn("set readonly=", result.stdout)
            self.assertNotIn("set canmount=", result.stdout)

    def test_exact_writable_mount_is_prepared(self):
        self.run_storage()

    def test_wrong_or_unavailable_mount_refuses_directory_creation(self):
        for values in (
            {"readonly": "on"},
            {"readonly": "-"},
            {"mounted": "no"},
            {"source": "/dev/root"},
            {"source": DATASET + "/child"},
            {"target": "/var/lib"},
            {"fs_type": "ext4"},
            {"findmnt_status": 1},
            {"property_status": 1},
        ):
            with self.subTest(values=values):
                self.run_storage(success=False, **values)


class SplitSourceTests(unittest.TestCase):
    """A bucket from a further source with its own credentials and limits."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = Store({KEY: b"checkpoint"})
        self.extra = Store({})
        self.extra.access = EXTRA_ACCESS
        self.extra.buckets = []
        # The extra source's reader may not list buckets.
        self.extra.fail_listing = "buckets"
        self.extra.bucket_objects["extra-bucket"] = {"wal/000000010000000000000001": b"wal"}
        self.replica = Store({})
        for store in (self.source, self.extra, self.replica):
            threading.Thread(target=store.serve_forever, daemon=True).start()
            self.addCleanup(store.server_close)
            self.addCleanup(store.shutdown)
        credentials = self.root / "credentials"
        credentials.mkdir()
        for name, value in (("s3_access_key", ACCESS), ("s3_secret_key", SECRET),
                            ("source_extra_access_key", EXTRA_ACCESS),
                            ("source_extra_secret_key", EXTRA_SECRET)):
            (credentials / name).write_text(value + "\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Each remote gets its own access and secret key, and no backend-wide
        # variable could override them.
        (self.bin / "rclone").write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            f"assert os.environ['RCLONE_CONFIG_SOURCE_ACCESS_KEY_ID'] == {ACCESS!r}\n"
            f"assert os.environ['RCLONE_CONFIG_SOURCE_SECRET_ACCESS_KEY'] == {SECRET!r}\n"
            f"assert os.environ['RCLONE_CONFIG_REPLICA_ACCESS_KEY_ID'] == {ACCESS!r}\n"
            f"assert os.environ['RCLONE_CONFIG_REPLICA_SECRET_ACCESS_KEY'] == {SECRET!r}\n"
            "if 'RCLONE_CONFIG_EXTRA_TYPE' in os.environ:\n"
            f"    assert os.environ['RCLONE_CONFIG_EXTRA_ACCESS_KEY_ID'] == {EXTRA_ACCESS!r}\n"
            f"    assert os.environ['RCLONE_CONFIG_EXTRA_SECRET_ACCESS_KEY'] == {EXTRA_SECRET!r}\n"
            "assert not [name for name in os.environ if name.startswith('RCLONE_S3_') and "
            "name.endswith(('ACCESS_KEY_ID', 'SECRET_ACCESS_KEY'))]\n"
            f"with open({str(self.root / 'calls')!r}, 'a') as f:\n"
            "    f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            # A replica inventory that fails, as after a sync.
            "if os.environ.get('FAIL_REPLICA_INVENTORY') and 'lsjson' in sys.argv and "
            "'--recursive' in sys.argv and sys.argv[-1].startswith('replica:'):\n"
            "    sys.exit(7)\n"
            f"os.execv({RCLONE!r}, [{RCLONE!r}] + sys.argv[1:])\n"
        )
        (self.bin / "rclone").chmod(0o755)
        (self.bin / "sleep").write_text("#!/bin/sh\nexit 0\n")
        (self.bin / "sleep").chmod(0o755)
        (self.bin / "zfs").write_text("#!/bin/sh\necho 'unexpected zfs' >&2\nexit 99\n")
        (self.bin / "zfs").chmod(0o755)
        (self.bin / "date").write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "+%a" ] && [ -n "$FAKE_WEEKDAY" ]; then\n'
            '  echo "$FAKE_WEEKDAY"\n'
            "  exit 0\n"
            "fi\n"
            f'exec {shutil.which("date")} "$@"\n'
        )
        (self.bin / "date").chmod(0o755)
        self.state = self.root / "state"
        self.state.mkdir()
        self.env = {
            "STATE_DIRECTORY": str(self.state),
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "HOME": str(self.root),
            "TMPDIR": str(self.root),
            "CREDENTIALS_DIRECTORY": str(credentials),
        }

    def run_mirror(self, success=True, script=SPLIT_SCRIPT, extra=None):
        (self.root / "calls").write_text("")
        script = script.replace("http://192.0.2.11:9000", self.source.endpoint)
        script = script.replace("http://192.0.2.12:9000", (extra or self.extra).endpoint)
        script = script.replace("http://192.0.2.10:9000", self.replica.endpoint)
        result = subprocess.run(["bash", "-c", script], env=self.env, text=True,
                                capture_output=True, timeout=30, check=False)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        calls = [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]
        for value in (ACCESS, SECRET, EXTRA_ACCESS, EXTRA_SECRET):
            self.assertNotIn(value, result.stdout + result.stderr + json.dumps(calls))
        return result, calls

    def test_each_bucket_comes_from_its_source_with_its_limit(self):
        result, calls = self.run_mirror()
        self.assertEqual(self.replica.bucket_objects["extra-bucket"],
                         {"wal/000000010000000000000001": b"wal"})
        self.assertEqual(self.replica.objects, {KEY: b"checkpoint"})
        syncs = {call[-2]: call for call in calls if "sync" in call}
        self.assertEqual(set(syncs), {"source:fixture", "extra:extra-bucket"})
        for remote, limit in (("source:fixture", "5M"), ("extra:extra-bucket", "10M")):
            call = syncs[remote]
            self.assertEqual(call[call.index("--bwlimit") + 1], limit)
            self.assertEqual(call[-1], "replica:" + remote.split(":", 1)[1])
        # Neither listing nor stat is rate limited.
        self.assertFalse([call for call in calls if "lsjson" in call and "--bwlimit" in call])
        self.assertIn("mirror source=extra bucket=extra-bucket scope=full bwlimit=10M",
                      result.stdout)
        # The extra source is never asked to list its buckets, and the default
        # source never serves the extra bucket.
        self.assertNotIn(("GET", ""), self.extra.requests)
        self.assertFalse([path for _, path in self.source.requests
                          if path.startswith("extra-bucket")])
        self.assertIn("verified bucket=extra-bucket", result.stdout)

    def test_an_extra_source_added_after_a_full_pass_gets_a_full_first_pass(self):
        self.env["FAKE_WEEKDAY"] = "Mon"
        # A Monday with no verified pass: full, from the default source only.
        result, calls = self.run_mirror(script=SPLIT_BASE_INCREMENTAL_SCRIPT)
        self.assertIn("mirror pass scope=full", result.stdout)
        self.assertNotIn("extra-bucket", self.replica.bucket_objects)
        # The extra source is added the next day. The pass is incremental, but
        # the new bucket's old object (2026-01-01) must arrive all the same.
        result, calls = self.run_mirror(script=SPLIT_INCREMENTAL_SCRIPT)
        self.assertIn("mirror pass scope=incremental", result.stdout)
        self.assertIn("bucket=fixture scope=incremental", result.stdout)
        self.assertIn("bucket=extra-bucket scope=full", result.stdout)
        self.assertEqual(self.replica.bucket_objects["extra-bucket"],
                         {"wal/000000010000000000000001": b"wal"})
        self.assertEqual([call[-2] for call in calls if "sync" in call], ["extra:extra-bucket"])
        self.assertEqual(self.markers(), {
            initialized_marker("source", self.source.endpoint, "fixture"),
            initialized_marker("extra", self.extra.endpoint, "extra-bucket")})
        # The run after that is incremental for both.
        result, calls = self.run_mirror(script=SPLIT_INCREMENTAL_SCRIPT)
        self.assertIn("bucket=extra-bucket scope=incremental", result.stdout)
        self.assertEqual([call for call in calls if "sync" in call], [])

    def markers(self):
        root = self.state / "initialized"
        return {path.relative_to(root) for path in root.rglob("*") if path.is_file()}

    def initialize(self):
        """A default-source full pass, then the extra source verified once."""
        self.env["FAKE_WEEKDAY"] = "Mon"
        self.run_mirror(script=SPLIT_BASE_INCREMENTAL_SCRIPT)
        result, _ = self.run_mirror(script=SPLIT_INCREMENTAL_SCRIPT)
        self.assertIn("bucket=extra-bucket scope=full", result.stdout)
        result, _ = self.run_mirror(script=SPLIT_INCREMENTAL_SCRIPT)
        self.assertIn("bucket=extra-bucket scope=incremental", result.stdout)

    def start(self, store):
        threading.Thread(target=store.serve_forever, daemon=True).start()
        self.addCleanup(store.server_close)
        self.addCleanup(store.shutdown)
        return store

    def test_a_repointed_endpoint_gets_a_full_pass(self):
        self.initialize()
        # The same remote name and bucket at a new endpoint, holding an older
        # object the old one never had.
        moved = Store({})
        moved.access = EXTRA_ACCESS
        moved.buckets = []
        moved.fail_listing = "buckets"
        moved.bucket_objects["extra-bucket"] = {
            "wal/000000010000000000000001": b"wal", "base/old": b"older base backup"}
        self.start(moved)
        result, calls = self.run_mirror(script=SPLIT_INCREMENTAL_SCRIPT, extra=moved)
        self.assertIn("mirror pass scope=incremental", result.stdout)
        self.assertIn("bucket=extra-bucket scope=full", result.stdout)
        self.assertEqual(self.replica.bucket_objects["extra-bucket"]["base/old"],
                         b"older base backup")
        # Only the new assignment's marker remains for the bucket.
        self.assertEqual(self.markers(), {
            initialized_marker("source", self.source.endpoint, "fixture"),
            initialized_marker("extra", moved.endpoint, "extra-bucket")})
        result, calls = self.run_mirror(script=SPLIT_INCREMENTAL_SCRIPT, extra=moved)
        self.assertIn("bucket=extra-bucket scope=incremental", result.stdout)

    def test_a_bucket_moved_away_and_back_gets_a_full_pass(self):
        self.initialize()
        # The bucket moves to the default source, which verifies it in full...
        self.source.buckets = ["fixture", "extra-bucket"]
        self.source.bucket_objects["extra-bucket"] = {"wal/000000010000000000000001": b"wal"}
        result, calls = self.run_mirror(script=SPLIT_BASE_INCREMENTAL_SCRIPT)
        self.assertIn("mirror source=source bucket=extra-bucket scope=full", result.stdout)
        self.assertNotIn(initialized_marker("extra", self.extra.endpoint, "extra-bucket"),
                         self.markers())
        # ...and moves back, where an older object now waits.
        self.source.buckets = ["fixture"]
        self.extra.bucket_objects["extra-bucket"]["base/old"] = b"older base backup"
        result, calls = self.run_mirror(script=SPLIT_INCREMENTAL_SCRIPT)
        self.assertIn("mirror source=extra bucket=extra-bucket scope=full", result.stdout)
        self.assertEqual(self.replica.bucket_objects["extra-bucket"]["base/old"],
                         b"older base backup")
        self.assertEqual(self.markers(), {
            initialized_marker("source", self.source.endpoint, "fixture"),
            initialized_marker("extra", self.extra.endpoint, "extra-bucket")})

    def test_a_bucket_back_in_the_plan_gets_a_full_pass(self):
        self.env["FAKE_WEEKDAY"] = "Mon"
        self.source.buckets = ["fixture", "second"]
        self.source.bucket_objects["second"] = {"dump/1": b"first dump"}
        # Both buckets are verified, then a pass is incremental for both.
        result, _ = self.run_mirror(script=SPLIT_BASE_INCREMENTAL_SCRIPT)
        self.assertIn("mirror pass scope=full", result.stdout)
        result, _ = self.run_mirror(script=SPLIT_BASE_INCREMENTAL_SCRIPT)
        self.assertIn("bucket=second scope=incremental", result.stdout)
        # second leaves the plan for one pass while fixture passes and
        # last-verified advances; its markers go.
        self.source.buckets = ["fixture"]
        # Backdated, so the pass's advance is visible within one second.
        verified = int(time.time()) - 7200
        (self.state / "last-verified").write_text(f"{verified}\n")
        result, calls = self.run_mirror(script=SPLIT_BASE_INCREMENTAL_SCRIPT)
        self.assertNotIn("bucket=second", result.stdout)
        self.assertGreater(int((self.state / "last-verified").read_text()), verified)
        self.assertEqual(self.markers(), {
            initialized_marker("source", self.source.endpoint, "fixture")})
        # It received an object while out, older than the last verified pass,
        # so an incremental pass would never copy it.
        self.source.bucket_objects["second"]["dump/2"] = b"written while out"
        self.source.buckets = ["fixture", "second"]
        result, calls = self.run_mirror(script=SPLIT_BASE_INCREMENTAL_SCRIPT)
        self.assertIn("mirror pass scope=incremental", result.stdout)
        self.assertIn("bucket=fixture scope=incremental", result.stdout)
        self.assertIn("bucket=second scope=full", result.stdout)
        self.assertEqual(self.replica.bucket_objects["second"]["dump/2"], b"written while out")

    def test_a_failed_pass_after_reassignment_still_forces_a_full_pass_back(self):
        # Assignment A (the extra endpoint) holds an older object and is
        # verified, so the replica has it.
        self.extra.bucket_objects["extra-bucket"]["base/old"] = b"older base backup"
        self.initialize()
        self.assertIn("base/old", self.replica.bucket_objects["extra-bucket"])
        # Assignment B lacks it. Its full sync deletes it from the replica, and
        # the inventory after the sync fails, so the pass fails.
        other = Store({})
        other.access = EXTRA_ACCESS
        other.buckets = []
        other.fail_listing = "buckets"
        other.bucket_objects["extra-bucket"] = {"wal/000000010000000000000001": b"wal"}
        self.start(other)
        self.env["FAIL_REPLICA_INVENTORY"] = "1"
        result, calls = self.run_mirror(success=False, script=SPLIT_INCREMENTAL_SCRIPT,
                                        extra=other)
        del self.env["FAIL_REPLICA_INVENTORY"]
        self.assertIn("bucket=extra-bucket scope=full", result.stdout)
        self.assertIn("extra:extra-bucket", [call[-2] for call in calls if "sync" in call])
        self.assertNotIn("base/old", self.replica.bucket_objects["extra-bucket"])
        # Neither assignment counts as verified for the bucket any more.
        self.assertEqual(self.markers(), {
            initialized_marker("source", self.source.endpoint, "fixture")})
        # Back to A: a full pass, which restores the older object.
        result, calls = self.run_mirror(script=SPLIT_INCREMENTAL_SCRIPT)
        self.assertIn("mirror pass scope=incremental", result.stdout)
        self.assertIn("bucket=extra-bucket scope=full", result.stdout)
        self.assertEqual(self.replica.bucket_objects["extra-bucket"]["base/old"],
                         b"older base backup")

    def test_an_empty_default_source_is_fine_while_another_supplies_buckets(self):
        self.source.buckets = []
        result, calls = self.run_mirror()
        self.assertIn("verified bucket=extra-bucket", result.stdout)
        self.assertEqual([call[-2] for call in calls if "sync" in call], ["extra:extra-bucket"])

    def test_an_empty_default_source_that_had_buckets_is_refused(self):
        result, _ = self.run_mirror()
        record = self.state / "default-source-had-buckets"
        self.assertTrue(record.exists())
        # The default source now lists nothing, though extra sources still
        # supply buckets: the pass refuses before any change.
        self.source.buckets = []
        replica = dict(self.replica.objects)
        result, calls = self.run_mirror(success=False)
        self.assertIn("the default backup source lists no buckets, but a verified pass saw "
                      "some; refusing", result.stderr)
        self.assertFalse([call for call in calls
                          if "sync" in call or "copy" in call or "mkdir" in call])
        self.assertEqual(self.replica.objects, replica)
        # Removing the record, as the operator would for an intended change,
        # lets the pass run from the extra source alone.
        record.unlink()
        result, calls = self.run_mirror()
        self.assertEqual([call[-2] for call in calls if "sync" in call], ["extra:extra-bucket"])
        self.assertFalse(record.exists())

    def test_a_pass_with_nothing_to_mirror_is_refused(self):
        self.source.buckets = []
        result, calls = self.run_mirror(success=False, script=SPLIT_BASE_INCREMENTAL_SCRIPT)
        self.assertIn("the backup sources contain no buckets; refusing an empty mirror",
                      result.stderr)
        self.assertFalse([call for call in calls if "sync" in call or "mkdir" in call])

    def test_a_bucket_on_both_sources_refuses_before_any_copy(self):
        self.source.buckets = ["fixture", "extra-bucket"]
        result, calls = self.run_mirror(success=False)
        self.assertIn("bucket extra-bucket is on the default source but mirrored from another "
                      "source; refusing", result.stderr)
        self.assertFalse([call for call in calls if "sync" in call or "copy" in call])


class LocalBackupTests(unittest.TestCase):
    def test_disabled_manual_k8s_invocation_refuses_before_storage_access(self):
        prelude = """
id() { printf '0\\n'; }
zpool() { echo 'unexpected zpool access' >&2; return 99; }
zfs() { echo 'unexpected zfs access' >&2; return 99; }
set -- k8s
"""
        result = subprocess.run(
            ["bash", "-c", prelude + LOCAL_BACKUP_SCRIPT],
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "replication is disabled; refusing manual k8s invocation", result.stderr
        )
        self.assertNotIn("unexpected", result.stderr)


if __name__ == "__main__":
    unittest.main()
