#!/usr/bin/env python3
"""Serve exactly one self-contained HTML report locally or on the LAN."""

from __future__ import annotations

import argparse
import html
import http.server
import ipaddress
import mimetypes
import socket
import sys
import threading
import webbrowser
from pathlib import Path
from urllib.parse import unquote, urlsplit


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        prog="nixbox-report",
        description="Open one self-contained HTML report through a minimal HTTP server.",
    )
    result.add_argument("report", type=Path, help="standalone HTML report to serve")
    result.add_argument(
        "--lan",
        action="store_true",
        help="bind only to the default private LAN address instead of loopback",
    )
    result.add_argument(
        "--bind",
        metavar="ADDRESS",
        help="bind to this exact address; implies LAN mode when not loopback",
    )
    result.add_argument(
        "--port",
        type=int,
        default=0,
        help="TCP port (default: choose a free ephemeral port)",
    )
    result.add_argument(
        "--no-open",
        action="store_true",
        help="print the URL without opening the local default browser",
    )
    return result


def default_route_address() -> str:
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # No packet needs to reach this documentation-only address; connect()
        # merely asks the kernel which source address its default route uses.
        probe.connect(("192.0.2.1", 9))
        address = probe.getsockname()[0]
    except OSError as error:
        raise SystemExit(f"unable to determine the default LAN address: {error}") from error
    finally:
        probe.close()

    parsed = ipaddress.ip_address(address)
    if not parsed.is_private or parsed.is_loopback or parsed.is_link_local:
        raise SystemExit(
            f"default route selected non-private address {address}; use --bind explicitly"
        )
    return address


def bind_address(arguments: argparse.Namespace) -> str:
    if arguments.bind:
        try:
            parsed = ipaddress.ip_address(arguments.bind)
        except ValueError as error:
            raise SystemExit(f"invalid --bind address: {arguments.bind}") from error
        if parsed.version != 4:
            raise SystemExit("nixbox-report currently accepts an IPv4 --bind address")
        return str(parsed)
    if arguments.lan:
        return default_route_address()
    return "127.0.0.1"


def report_handler(report: Path) -> type[http.server.BaseHTTPRequestHandler]:
    payload = report.read_bytes()
    content_type = mimetypes.guess_type(report.name)[0] or "text/html"
    allowed_paths = {"/", f"/{report.name}"}

    class ReportHandler(http.server.BaseHTTPRequestHandler):
        def send_report(self, include_body: bool) -> None:
            request_path = unquote(urlsplit(self.path).path)
            if request_path not in allowed_paths:
                body = b"Not found\n"
                self.send_response(http.HTTPStatus.NOT_FOUND)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if include_body:
                    self.wfile.write(body)
                return

            self.send_response(http.HTTPStatus.OK)
            self.send_header("Content-Type", f"{content_type}; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header(
                "Content-Security-Policy",
                "default-src 'none'; style-src 'unsafe-inline'; "
                "script-src 'unsafe-inline'; img-src data:; base-uri 'none'; "
                "form-action 'none'",
            )
            self.end_headers()
            if include_body:
                self.wfile.write(payload)

        def do_HEAD(self) -> None:  # noqa: N802 - stdlib callback name
            self.send_report(include_body=False)

        def do_GET(self) -> None:  # noqa: N802 - stdlib callback name
            self.send_report(include_body=True)

        def log_message(self, message: str, *values: object) -> None:
            rendered = message % values
            print(f"request: {html.escape(rendered, quote=False)}", file=sys.stderr)

    return ReportHandler


def main() -> int:
    arguments = parser().parse_args()
    report = arguments.report.expanduser().resolve()
    if not report.is_file():
        raise SystemExit(f"report does not exist: {report}")
    if report.suffix.lower() not in {".html", ".htm"}:
        raise SystemExit("report must be a standalone .html or .htm file")
    if not 0 <= arguments.port <= 65535:
        raise SystemExit("--port must be between 0 and 65535")

    address = bind_address(arguments)
    server = http.server.ThreadingHTTPServer(
        (address, arguments.port), report_handler(report)
    )
    port = server.server_address[1]
    url = f"http://{address}:{port}/"
    scope = "LAN" if address != "127.0.0.1" else "this machine"
    print(f"Serving {report.name} to {scope}")
    print(url, flush=True)
    print("Press Ctrl+C to stop.", flush=True)

    if not arguments.no_open:
        threading.Timer(0.2, webbrowser.open, args=(url,)).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
