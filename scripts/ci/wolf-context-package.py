#!/usr/bin/env python3
"""Bounded Forgejo transport for committed Wolf image contexts."""

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.error
import urllib.parse
import urllib.request

PRODUCTS = ("wolf", "helium", "brave", "zen")
SHA = re.compile(r"[0-9a-f]{40}\Z")


class SafeError(Exception):
    """An error whose fixed message contains no credential or response data."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, url):
        raise SafeError("Forgejo transport refused a redirect")


def validate(args):
    if args.channel not in ("dev", "main") or not SHA.fullmatch(args.sha):
        raise SafeError("expected a trusted channel and full source revision")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.owner):
        raise SafeError("invalid package owner")
    parsed = urllib.parse.urlsplit(args.url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise SafeError("Forgejo URL must be an HTTPS origin")
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise SafeError("Forgejo URL must be an HTTPS origin")


def auth_header(args):
    if args.docker_config:
        config = json.loads(Path(args.docker_config).read_text())
        origin = urllib.parse.urlsplit(args.url).netloc
        encoded = config["auths"][origin]["auth"]
        # Only a Docker-config Basic credential is accepted; no helper execution.
        if b":" not in base64.b64decode(encoded, validate=True):
            raise SafeError("Docker credential is invalid")
        return "Basic " + encoded
    if args.token_file or args.token_env:
        token = (Path(args.token_file).read_text() if args.token_file else os.environ[args.token_env]).strip()
        if not token or "\n" in token or "\r" in token:
            raise SafeError("Package token file is invalid")
        encoded = base64.b64encode((args.user + ":" + token).encode()).decode()
        return "Basic " + encoded
    raise SafeError("a package credential file is required")


def request(args, method, path, *, payload=None, output=None, allowed=(200, 201, 204)):
    url = args.url.rstrip("/") + path
    headers = {"Authorization": auth_header(args), "User-Agent": "wolf-context-handoff/1"}
    if payload is not None:
        headers["Content-Type"] = "application/octet-stream"
    if isinstance(payload, Path):
        headers["Content-Length"] = str(payload.stat().st_size)
        payload = payload.open("rb")
    req = urllib.request.Request(url, data=payload, headers=headers, method=method)
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(req, timeout=180) as response:
            if response.status not in allowed:
                raise SafeError(f"Forgejo transport returned HTTP {response.status}")
            if output is not None:
                with Path(output).open("wb") as destination:
                    shutil.copyfileobj(response, destination, 1024 * 1024)
                return b""
            return response.read()
    except urllib.error.HTTPError as exc:
        if exc.code == 404 and 404 in allowed:
            return None
        raise SafeError(f"Forgejo transport returned HTTP {exc.code}") from None
    except urllib.error.URLError:
        raise SafeError("Forgejo transport connection failed") from None
    finally:
        if hasattr(payload, "close"):
            payload.close()


def package_name(args):
    return f"wolf-context-{args.channel}"


def file_path(args, filename, sha=None):
    version = sha or args.sha
    return "/api/packages/{}/generic/{}/{}/{}".format(
        urllib.parse.quote(args.owner), package_name(args), version, filename
    )


def receipt_path(args):
    return file_path(args, "complete.json")


def remote_files(args):
    path = "/api/v1/packages/{}/generic/{}/{}/files".format(
        urllib.parse.quote(args.owner), package_name(args), args.sha
    )
    data = request(args, "GET", path, allowed=(200, 404))
    if data is None:
        return {}
    files = json.loads(data)
    return {item["name"]: item["sha256"] for item in files}


def upload(args):
    receipt = json.loads(Path(args.receipt).read_text())
    if receipt.get("revision") != args.sha or receipt.get("channel") != args.channel:
        raise SafeError("receipt does not match requested source revision")
    if set(receipt.get("products", {})) != set(PRODUCTS):
        raise SafeError("receipt must contain exactly the deployed products")
    files = remote_files(args)
    if "complete.json" in files:
        raise SafeError("completed package version already exists")
    for product in PRODUCTS:
        expected = receipt["products"][product]
        archive = Path(args.directory) / f"{product}.tar.zst"
        if not SHA256.fullmatch(expected) or digest(archive) != expected:
            raise SafeError(f"archive checksum mismatch for {product}")
        if archive.name in files:
            if files[archive.name] != expected:
                raise SafeError(f"existing package file differs for {product}")
        else:
            request(args, "PUT", file_path(args, archive.name), payload=archive)
    request(args, "PUT", receipt_path(args), payload=Path(args.receipt))


SHA256 = re.compile(r"[0-9a-f]{64}\Z")


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            h.update(block)
    return h.hexdigest()


def download(args):
    receipt_bytes = request(args, "GET", receipt_path(args), allowed=(200, 404))
    if receipt_bytes is None:
        raise SafeError("exact-revision Wolf context package is not complete")
    receipt = json.loads(receipt_bytes)
    if receipt.get("schemaVersion") != 1 or receipt.get("revision") != args.sha or receipt.get("channel") != args.channel:
        raise SafeError("Wolf context receipt has the wrong revision or channel")
    expected = receipt.get("products", {}).get(args.product)
    if not isinstance(expected, str) or not SHA256.fullmatch(expected):
        raise SafeError("Wolf context receipt lacks this product")
    archive = Path(args.output)
    request(args, "GET", file_path(args, f"{args.product}.tar.zst"), output=archive)
    if digest(archive) != expected:
        archive.unlink(missing_ok=True)
        raise SafeError("Wolf context archive checksum mismatch")


def exists(args):
    present = request(args, "HEAD", receipt_path(args), allowed=(200, 404)) is not None
    print("present" if present else "missing")


def extract(args):
    root = Path(args.directory).resolve()
    root.mkdir(parents=True, exist_ok=True)
    process = subprocess.Popen(
        ["zstd", "-dc", "--", args.archive], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
    )
    directories = []
    try:
        with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
            for member in archive:
                path = Path(member.name)
                if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
                    raise SafeError("Wolf context archive has an unsafe path")
                if path.parts[0] not in ("context", "manifest.json"):
                    raise SafeError("Wolf context archive has an unexpected path")
                destination = root / path
                if not destination.resolve().is_relative_to(root):
                    raise SafeError("Wolf context archive escapes its workspace")
                if member.isdir():
                    destination.mkdir(parents=True, exist_ok=True)
                    directories.append((destination, member.mode & 0o777))
                elif member.isfile():
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(member) as source, destination.open("xb") as target:
                        shutil.copyfileobj(source, target, 1024 * 1024)
                    destination.chmod(member.mode & 0o777)
                else:
                    raise SafeError("Wolf context archive contains a link or special file")
        if process.wait() != 0:
            raise SafeError("Wolf context archive decompression failed")
        for destination, mode in sorted(directories, key=lambda item: len(item[0].parts), reverse=True):
            destination.chmod(mode)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        process.stdout.close()


def prune(args):
    # The completion file is uploaded last. Old partial versions age out too.
    packages = []
    page = 1
    while True:
        query = urllib.parse.urlencode({"type": "generic", "q": package_name(args), "limit": 100, "page": page})
        data = json.loads(request(args, "GET", f"/api/v1/packages/{urllib.parse.quote(args.owner)}?{query}"))
        packages.extend(item for item in data if item.get("name") == package_name(args) and SHA.fullmatch(item.get("version", "")))
        if not data:
            break
        page += 1
    packages.sort(key=lambda item: item.get("created_at", ""), reverse=True)
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=24)
    for item in packages[2:]:
        created = dt.datetime.fromisoformat(item["created_at"].replace("Z", "+00:00"))
        if created >= cutoff:
            continue
        version = item["version"]
        if version == args.sha:
            continue
        path = "/api/v1/packages/{}/generic/{}/{}".format(
            urllib.parse.quote(args.owner), package_name(args), version
        )
        request(args, "DELETE", path)


def dispatch(args):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.repo):
        raise SafeError("invalid dispatch repository")
    token = Path(args.api_token_file).read_text().strip()
    if not token or "\n" in token or "\r" in token:
        raise SafeError("dispatch credential is invalid")
    path = f"/api/v1/repos/{args.owner}/{args.repo}/actions/workflows/publish-wolf-images.yml/dispatches"
    body = json.dumps({"ref": args.sha, "inputs": {"channel": args.channel, "source_sha": args.sha, "publish": "true"}}).encode()
    req = urllib.request.Request(
        args.url.rstrip("/") + path,
        data=body,
        headers={"Authorization": "token " + token, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.build_opener(NoRedirect).open(req, timeout=30) as response:
            if response.status not in (201, 204):
                raise SafeError(f"dispatch returned HTTP {response.status}")
    except urllib.error.HTTPError as exc:
        raise SafeError(f"dispatch returned HTTP {exc.code}") from None
    except urllib.error.URLError:
        raise SafeError("dispatch connection failed") from None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("upload", "download", "prune", "dispatch", "exists", "extract"))
    parser.add_argument("--url", required=True)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--channel", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--docker-config")
    parser.add_argument("--token-file")
    parser.add_argument("--token-env")
    parser.add_argument("--user")
    parser.add_argument("--directory")
    parser.add_argument("--receipt")
    parser.add_argument("--product", choices=PRODUCTS)
    parser.add_argument("--output")
    parser.add_argument("--repo")
    parser.add_argument("--api-token-file")
    parser.add_argument("--archive")
    args = parser.parse_args()
    try:
        validate(args)
        if args.command == "extract":
            extract(args)
        elif args.command == "upload":
            upload(args)
        elif args.command == "download":
            download(args)
        elif args.command == "prune":
            prune(args)
        elif args.command == "exists":
            exists(args)
        else:
            dispatch(args)
    except SafeError as exc:
        print(f"Wolf context package: {exc}", file=sys.stderr)
        return 1
    except Exception:
        print("Wolf context package: invalid input or transport response", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
