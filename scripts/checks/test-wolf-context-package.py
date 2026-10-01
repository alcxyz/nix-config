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
PRODUCER = SOURCE.with_name("run-local-wolf-contexts.sh")
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

    def test_producer_packs_hardlinked_files_as_regular_files(self):
        if shutil.which("zstd") is None:
            self.skipTest("zstd is unavailable")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage"
            context = stage / "context"
            context.mkdir(parents=True)
            (context / "first").write_bytes(b"shared payload\n")
            os.link(context / "first", context / "second")
            (stage / "manifest.json").write_text("{}\n")
            linked = root / "linked.tar.zst"
            subprocess.run(["tar", "--zstd", "-cf", str(linked), "-C", str(stage),
                            "context", "manifest.json"], check=True)
            args = self.args(root)
            args.archive = str(linked)
            args.directory = str(root / "rejected")
            with self.assertRaisesRegex(module.SafeError, "link or special file"):
                module.extract(args)

            packed = root / "context.tar.zst"
            subprocess.run(["bash", str(PRODUCER), "--pack-context", str(stage), str(packed)], check=True)

            with subprocess.Popen(["zstd", "-dc", str(packed)], stdout=subprocess.PIPE) as process:
                with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
                    entries = {member.name: member.type for member in archive}
                self.assertEqual(process.wait(), 0)
            self.assertEqual(entries["context/first"], tarfile.REGTYPE)
            self.assertEqual(entries["context/second"], tarfile.REGTYPE)

            args = self.args(root)
            args.archive = str(packed)
            args.directory = str(root / "output")
            module.extract(args)
            self.assertEqual((root / "output/context/first").read_bytes(), b"shared payload\n")
            self.assertEqual((root / "output/context/second").read_bytes(), b"shared payload\n")

    def test_producer_compares_all_product_inputs(self):
        if shutil.which("jq") is None:
            self.skipTest("jq is unavailable")
        products = [{"name": name, "context": f"/nix/store/{name}-context",
                     "buildArgs": {"RUNTIME_IMAGE": "runtime:1"},
                     "labels": {"io.nixbox.wolf-browser.context": f"/nix/store/{name}-context"}}
                    for name in ("wolf", "helium", "brave", "zen")]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def write(name, items):
                path = root / name
                path.write_text(json.dumps({"schemaVersion": 1, "products": items}))
                return path

            def variant(field, value):
                items = json.loads(json.dumps(products))
                items[3][field] = value
                return items

            def same(new, old):
                return subprocess.run(["bash", str(PRODUCER), "--same-products", str(new), str(old)]).returncode

            current = write("current.json", products)
            # Product order does not matter.
            self.assertEqual(same(current, write("reordered.json", list(reversed(products)))), 0)
            # Any image input differs: context, build arguments or labels.
            self.assertNotEqual(same(current, write("context.json", variant("context", "/nix/store/zen-new"))), 0)
            self.assertNotEqual(same(current, write("args.json", variant("buildArgs", {"RUNTIME_IMAGE": "runtime:2"}))), 0)
            self.assertNotEqual(same(current, write("labels.json", variant("labels", {}))), 0)
            # A missing or unreadable previous record never suppresses publishing.
            self.assertNotEqual(same(current, root / "missing.json"), 0)
            (root / "broken.json").write_text("{not json")
            self.assertNotEqual(same(current, root / "broken.json"), 0)

    def test_producer_skips_only_after_a_dispatch_with_identical_inputs(self):
        tools = ("git", "jq", "rg", "fd", "flock", "tar", "zstd", "awk")
        if any(shutil.which(tool) is None for tool in tools):
            self.skipTest("producer tools are unavailable")
        # A small real store directory without links serves as every context.
        context = Path(shutil.which("jq")).resolve().parents[1]
        if not str(context).startswith("/nix/store/") or any(
                path.is_symlink() for path in context.rglob("*")):
            self.skipTest("no link-free store directory is available")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote, source, shims, state, log = (root / name for name in
                                                 ("remote.git", "source", "bin", "state", "calls"))
            shims.mkdir()
            log.write_text("")
            for name, body in {
                # Out-link a product directory whose manifest comes from products.json.
                "nix": """#!/usr/bin/env bash
set -eu
link=; while [[ $# -gt 0 ]]; do [[ $1 == --out-link ]] && { link=$2; shift; }; shift; done
product=$(mktemp -d "$MOCK_ROOT/product.XXXX")
jq '{schemaVersion: 1, products: .}' products.json >"$product/manifest.json"
ln -s "$product" "$link"
""",
                "nix-store": """#!/usr/bin/env bash
set -eu
[[ ! -e $MOCK_ROOT/fail-root ]] || exit 1
path=$2; while [[ $# -gt 0 ]]; do [[ $1 == --add-root ]] && root=$2; shift; done
ln -sfn "$path" "$root"
""",
            }.items():
                # The build sandbox has no /usr/bin/env; use an absolute shell.
                (shims / name).write_text(body.replace("#!/usr/bin/env bash", "#!" + shutil.which("bash"), 1))
                (shims / name).chmod(0o755)

            subprocess.run(["git", "init", "-q", "--bare", "-b", "dev", str(remote)], check=True)
            subprocess.run(["git", "init", "-q", "-b", "dev", str(source)], check=True)
            client = source / "scripts/ci/wolf-context-package.py"
            client.parent.mkdir(parents=True)
            shutil.copy(PRODUCER, source / "scripts/ci/run-local-wolf-contexts.sh")
            client.write_text("""import os, sys
action = sys.argv[1]
with open(os.environ["MOCK_LOG"], "a") as log:
    log.write(action + "\\n")
if action == "exists":
    marker = os.environ["MOCK_ROOT"] + "/exists"
    print(open(marker).read().strip() if os.path.exists(marker) else "missing")
if action == "dispatch" and os.path.exists(os.environ["MOCK_ROOT"] + "/fail-dispatch"):
    sys.exit(1)
""")
            products = [{"name": name, "context": str(context), "buildArgs": {}, "labels": {}}
                        for name in ("wolf", "helium", "brave", "zen")]

            def commit(lock, items=products):
                (source / "flake.lock").write_text(lock)
                (source / "products.json").write_text(json.dumps(items))
                subprocess.run(["git", "-C", str(source), "add", "-A"], check=True)
                subprocess.run(["git", "-C", str(source), "-c", "user.name=t", "-c", "user.email=t@t",
                                "commit", "-qm", lock], check=True)
                subprocess.run(["git", "-C", str(source), "push", "-qf", str(remote), "dev"], check=True)

            def produce():
                log.write_text("")
                token = root / "token"
                token.write_text("x")
                env = dict(os.environ, PATH=f"{shims}:{os.environ['PATH']}", MOCK_ROOT=str(root),
                           MOCK_LOG=str(log), CONFIG_REMOTE=str(remote), CONFIG_BRANCH="dev",
                           FORGEJO_URL="https://forge.invalid", FORGEJO_OWNER="o", FORGEJO_REPO="r",
                           FORGEJO_API_TOKEN_FILE=str(token), DOCKER_CONFIG_FILE=str(token),
                           WOLF_CONTEXT_STATE_DIRECTORY=str(state), XDG_RUNTIME_DIR=str(root))
                result = subprocess.run(["bash", str(PRODUCER)], env=env, capture_output=True, text=True)
                return result.returncode, log.read_text().split()

            commit("lock-1")
            self.assertEqual(produce(), (0, ["exists", "upload", "dispatch", "prune"]))
            # An input-neutral lock bump records the revision without publishing.
            commit("lock-2")
            self.assertEqual(produce(), (0, ["exists"]))
            # A changed image input publishes.
            changed = [dict(item, buildArgs={"RUNTIME_IMAGE": "new"}) for item in products]
            commit("lock-3", changed)
            self.assertEqual(produce(), (0, ["exists", "upload", "dispatch", "prune"]))
            # A failed dispatch must not let identical inputs skip the next publish.
            (root / "fail-dispatch").touch()
            commit("lock-4", products)
            code, calls = produce()
            self.assertNotEqual(code, 0)
            self.assertEqual(calls, ["exists", "upload", "dispatch"])
            (root / "fail-dispatch").unlink()
            commit("lock-5", products)
            self.assertEqual(produce(), (0, ["exists", "upload", "dispatch", "prune"]))

            # Root registration fails after upload; the retry finds the upload,
            # dispatches it and records this revision's products.
            moved = [dict(item, labels={"moved": "yes"}) for item in products]
            (root / "fail-root").touch()
            commit("lock-6", moved)
            code, calls = produce()
            self.assertNotEqual(code, 0)
            self.assertEqual(calls, ["exists", "upload"])
            (root / "fail-root").unlink()
            (root / "exists").write_text("present")
            self.assertEqual(produce(), (0, ["exists", "dispatch", "prune"]))
            (root / "exists").unlink()
            commit("lock-7", moved)
            self.assertEqual(produce(), (0, ["exists"]))

            # Without proof of which revision was uploaded, no record is kept and
            # identical inputs publish again.
            (state / "dev.uploaded.json").unlink()
            (root / "exists").write_text("present")
            commit("lock-8", products)
            self.assertEqual(produce(), (0, ["exists", "dispatch", "prune"]))
            (root / "exists").unlink()
            self.assertFalse((state / "dev.dispatched.json").exists())
            commit("lock-9", products)
            self.assertEqual(produce(), (0, ["exists", "upload", "dispatch", "prune"]))

if __name__ == "__main__":
    unittest.main()
