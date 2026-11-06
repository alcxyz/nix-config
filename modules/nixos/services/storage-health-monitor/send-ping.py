#!/usr/bin/env python3
"""Send a storage heartbeat using a runtime capability file, without logging it."""
from pathlib import Path
import json
import re
import subprocess
import sys
import urllib.parse


def send(mode, filename, slug, suffix, report, run=None):
    if mode not in ("base", "check") or suffix not in ("", "/start", "/fail"):
        raise ValueError("invalid heartbeat mode")
    if not re.fullmatch(r"[a-z0-9-]+", slug):
        raise ValueError("invalid heartbeat slug")
    endpoint = Path(filename).read_text().strip()
    parsed = urllib.parse.urlsplit(endpoint)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or "?" in endpoint or "#" in endpoint
            or any(character.isspace() or ord(character) < 32 or ord(character) == 127
                   or character in ('"', "\\") for character in endpoint)):
        raise ValueError("invalid heartbeat endpoint")
    url = endpoint.rstrip("/")
    if mode == "base":
        url += "/" + slug
    url += suffix
    if mode == "base":
        url += "?create=1"
    # Keep capabilities out of argv. Curl retains its native address fallback
    # and one transfer deadline, including TLS and response reads.
    config = "url = " + json.dumps(url, ensure_ascii=False) + "\n"
    config += "data-binary = " + json.dumps("@" + str(report), ensure_ascii=False) + "\n"
    if run is None:
        run = subprocess.run
    result = run(
        ["curl", "--disable", "--config", "-", "--globoff", "--silent", "--fail",
         "--max-time", "10", "--output", "/dev/null", "--write-out", "%{http_code}",
         "--user-agent", "storage-health-monitor/1", "--header", "Content-Type: text/plain"],
        input=config.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    # No redirect option is supplied, and ambient curl configuration is disabled.
    # A 3xx response is a failure even though curl itself can exit successfully.
    if result.returncode or re.fullmatch(rb"2[0-9]{2}", result.stdout) is None:
        raise RuntimeError("heartbeat transport failed")


def main(argv):
    try:
        send(*argv)
    except Exception:
        # Exceptions can contain the capability URL or request contents.
        print("storage health heartbeat failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
