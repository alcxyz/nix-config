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
SNAPSHOT_SCRIPT = Path(sys.argv.pop(1)).read_text()
STORAGE_SCRIPT = Path(sys.argv.pop(1)).read_text()
LOCAL_BACKUP_SCRIPT = Path(sys.argv.pop(1)).read_text()
SNAPSHOT_PROPERTY = "org.nix-config:k8s-backup-s3-mirror"
DATASET = "fixture/k8s-backups"
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
        if ACCESS not in self.headers.get("Authorization", ""):
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
                    bucket_objects[f"new-{store.listings}"] = b"new"
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
        elif self.command == "PUT":
            data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if key and (store.fail_put or store.put_failures > 0):
                store.put_failures = max(0, store.put_failures - 1)
                self.reply(403, b"<Error><Code>AccessDenied</Code></Error>")
            else:
                if key:
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
            f"assert os.environ['RCLONE_S3_ACCESS_KEY_ID'] == {ACCESS!r}\n"
            f"assert os.environ['RCLONE_S3_SECRET_ACCESS_KEY'] == {SECRET!r}\n"
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
            "    assert args[3].startswith(dataset + '@k8s-backup-s3-mirror-'), args\n"
            "    snapshots.append({'name': args[3], 'value': 'verified', 'source': 'local'})\n"
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
        self.env = {
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "HOME": str(self.root),
            "TMPDIR": str(self.root),
            "CREDENTIALS_DIRECTORY": str(credentials),
        }

    def run_mirror(self, *, success=True, stat_size=None, zfs_failure=None):
        if zfs_failure:
            self.env["ZFS_FAILURE"] = zfs_failure
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
