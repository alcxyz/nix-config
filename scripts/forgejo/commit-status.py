#!/usr/bin/env python3
"""Read or publish one Forgejo commit status without exposing credentials."""

import argparse
import json
import os
import re
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request


SHA = re.compile(r"[0-9a-f]{40}")
STATES = {"pending", "success", "error", "failure", "warning"}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def endpoint(base_url, owner, repo, sha, suffix):
    parsed = urllib.parse.urlsplit(base_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.query or parsed.fragment:
        raise ValueError("invalid Forgejo URL")
    if not SHA.fullmatch(sha):
        raise ValueError("invalid commit revision")
    for value in (owner, repo):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", value):
            raise ValueError("invalid repository identity")
    root = base_url.rstrip("/")
    quoted_owner = urllib.parse.quote(owner, safe="")
    quoted_repo = urllib.parse.quote(repo, safe="")
    return f"{root}/api/v1/repos/{quoted_owner}/{quoted_repo}/{suffix}/{sha}"


def request_json(request):
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
            return json.load(response)
    except (OSError, ValueError, urllib.error.HTTPError, json.JSONDecodeError):
        print("Forgejo commit-status request failed", file=sys.stderr)
        raise SystemExit(1)


def require(args):
    url = endpoint(args.url, args.owner, args.repo, args.sha, "commits") + "/status"
    data = request_json(urllib.request.Request(url, headers={"Accept": "application/json"}))
    matches = [
        status for status in (data.get("statuses") or []) if status.get("context") == args.context
    ]
    latest = max(matches, key=lambda status: status.get("id", 0), default={})
    if latest.get("status") != "success":
        print(f"Required exact commit status is absent or unsuccessful: {args.context}", file=sys.stderr)
        return 1
    print(f"Required exact commit status succeeded: {args.context}")
    return 0


def publish(args):
    if args.state not in STATES:
        raise ValueError("invalid status state")
    try:
        token_fd = os.open(args.token_file, os.O_RDONLY | os.O_CLOEXEC)
        token_stat = os.fstat(token_fd)
        if not stat.S_ISREG(token_stat.st_mode) or token_stat.st_mode & 0o077:
            raise ValueError("credential file permissions are too broad")
        with os.fdopen(token_fd, encoding="utf-8") as source:
            token = source.read().strip()
    except (OSError, ValueError):
        print("Unable to read the Forgejo status credential", file=sys.stderr)
        return 1
    if not token or "\n" in token or "\r" in token:
        print("Invalid Forgejo status credential", file=sys.stderr)
        return 1

    url = endpoint(args.url, args.owner, args.repo, args.sha, "statuses")
    body = json.dumps(
        {"context": args.context, "description": args.description, "state": args.state}
    ).encode()
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Accept": "application/json",
            "Authorization": f"token {token}",
            "Content-Type": "application/json",
        },
    )
    request_json(request)
    print(f"Published exact commit status: {args.context} ({args.state})")
    return 0


def parser():
    result = argparse.ArgumentParser()
    subparsers = result.add_subparsers(dest="command", required=True)
    for name in ("require", "publish"):
        command = subparsers.add_parser(name)
        command.add_argument("--url", required=True)
        command.add_argument("--owner", required=True)
        command.add_argument("--repo", required=True)
        command.add_argument("--sha", required=True)
        command.add_argument("--context", required=True)
        if name == "publish":
            command.add_argument("--token-file", required=True)
            command.add_argument("--state", required=True)
            command.add_argument("--description", required=True)
    return result


def main():
    args = parser().parse_args()
    try:
        return require(args) if args.command == "require" else publish(args)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
