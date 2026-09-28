#!/usr/bin/env python3
"""Synthetic checks for the Wolf package handoff; no live credentials or API."""

import datetime as dt
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import types
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "ci/wolf-context-package.py"
spec = importlib.util.spec_from_file_location("wolf_context_package", SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
SHA = "a" * 40


class HandoffTests(unittest.TestCase):
    def args(self, root):
        return types.SimpleNamespace(
            channel="dev", sha=SHA, owner="fixture", url="https://example.invalid",
            directory=str(root), receipt=str(root / "complete.json"),
        )

    def test_partial_upload_resumes_exact_files_and_finishes_last(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hashes = {}
            for product in module.PRODUCTS:
                archive = root / f"{product}.tar.zst"
                archive.write_bytes(product.encode())
                hashes[product] = hashlib.sha256(product.encode()).hexdigest()
            (root / "complete.json").write_text(json.dumps({
                "schemaVersion": 1, "channel": "dev", "revision": SHA, "products": hashes,
            }))
            calls = []
            def request(_args, method, path, **kwargs):
                calls.append((method, path))
                return b""
            with mock.patch.object(module, "remote_files", return_value={"wolf.tar.zst": hashes["wolf"]}), \
                 mock.patch.object(module, "request", side_effect=request):
                module.upload(self.args(root))
            uploaded = [path.rsplit("/", 1)[-1] for method, path in calls if method == "PUT"]
            self.assertEqual(uploaded, ["helium.tar.zst", "brave.tar.zst", "zen.tar.zst", "complete.json"])

    def test_partial_upload_rejects_conflicting_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hashes = {}
            for product in module.PRODUCTS:
                (root / f"{product}.tar.zst").write_bytes(product.encode())
                hashes[product] = hashlib.sha256(product.encode()).hexdigest()
            (root / "complete.json").write_text(json.dumps({
                "schemaVersion": 1, "channel": "dev", "revision": SHA, "products": hashes,
            }))
            with mock.patch.object(module, "remote_files", return_value={"wolf.tar.zst": "0" * 64}), \
                 mock.patch.object(module, "request") as request:
                with self.assertRaises(module.SafeError):
                    module.upload(self.args(root))
                request.assert_not_called()

    def test_prune_keeps_newest_two_and_recent_then_deletes_old_partial(self):
        now = dt.datetime.now(dt.timezone.utc)
        def item(index, age_hours):
            return {"name": "wolf-context-dev", "version": f"{index:x}" * 40,
                    "created_at": (now - dt.timedelta(hours=age_hours)).isoformat()}
        versions = [item(1, 1), item(2, 2), item(3, 3), item(4, 30), item(5, 40)]
        args = self.args(Path("/tmp/fixture"))
        deleted = []
        def request(_args, method, path, **kwargs):
            if method == "GET":
                return json.dumps(versions if "page=1" in path else []).encode()
            if method == "DELETE":
                deleted.append(path.rsplit("/", 1)[-1])
                return b""
            raise AssertionError(method)
        with mock.patch.object(module, "request", side_effect=request):
            module.prune(args)
        self.assertEqual(deleted, [versions[3]["version"], versions[4]["version"]])

    def test_download_rejects_wrong_revision_before_archive_request(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = self.args(root)
            args.product = "wolf"
            args.output = str(root / "wolf.tar.zst")
            paths = []
            def request(_args, method, path, **kwargs):
                paths.append(path)
                return json.dumps({"schemaVersion": 1, "channel": "dev",
                                   "revision": "b" * 40, "products": {"wolf": "0" * 64}}).encode()
            with mock.patch.object(module, "request", side_effect=request):
                with self.assertRaises(module.SafeError):
                    module.download(args)
            self.assertEqual(len(paths), 1)
            self.assertFalse(Path(args.output).exists())

    def test_download_rejects_checksum_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = self.args(root)
            args.product = "wolf"
            args.output = str(root / "wolf.tar.zst")
            def request(_args, method, path, **kwargs):
                if path.endswith("complete.json"):
                    return json.dumps({"schemaVersion": 1, "channel": "dev",
                                       "revision": SHA, "products": {"wolf": "0" * 64}}).encode()
                Path(kwargs["output"]).write_bytes(b"wrong archive")
                return b""
            with mock.patch.object(module, "request", side_effect=request):
                with self.assertRaises(module.SafeError):
                    module.download(args)
            self.assertFalse(Path(args.output).exists())

    def test_extract_preserves_directory_and_file_modes(self):
        executable = shutil.which("zstd")
        if executable is None:
            self.skipTest("zstd is unavailable")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tar_path = root / "good.tar"
            with tarfile.open(tar_path, "w") as archive:
                context = tarfile.TarInfo("context")
                context.type = tarfile.DIRTYPE
                context.mode = 0o555
                archive.addfile(context)
                script = tarfile.TarInfo("context/start.sh")
                script.mode = 0o755
                script.size = 3
                archive.addfile(script, io.BytesIO(b"ok\n"))
            packed = root / "good.tar.zst"
            with packed.open("wb") as output:
                subprocess.run([executable, "-q", "-c", str(tar_path)], stdout=output, check=True,
                               env={"PATH": str(Path(executable).parent)})
            args = self.args(root)
            args.archive = str(packed)
            args.directory = str(root / "output")
            with mock.patch.dict(os.environ, {"PATH": str(Path(executable).parent)}, clear=True):
                module.extract(args)
            self.assertEqual((root / "output/context").stat().st_mode & 0o777, 0o555)
            self.assertEqual((root / "output/context/start.sh").stat().st_mode & 0o777, 0o755)

    def test_extract_rejects_archive_links(self):
        executable = shutil.which("zstd")
        if executable is None:
            self.skipTest("zstd is unavailable")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tar_path = root / "bad.tar"
            with tarfile.open(tar_path, "w") as archive:
                link = tarfile.TarInfo("context/escape")
                link.type = tarfile.SYMTYPE
                link.linkname = "../../outside"
                archive.addfile(link)
            packed = root / "bad.tar.zst"
            with packed.open("wb") as output:
                subprocess.run([executable, "-q", "-c", str(tar_path)], stdout=output, check=True,
                               env={"PATH": str(Path(executable).parent)})
            args = self.args(root)
            args.archive = str(packed)
            args.directory = str(root / "output")
            with mock.patch.dict(os.environ, {"PATH": str(Path(executable).parent)}, clear=True):
                with self.assertRaises(module.SafeError):
                    module.extract(args)
            self.assertFalse((root / "outside").exists())


if __name__ == "__main__":
    unittest.main()
