#!/usr/bin/env python3
"""Remove stale public Wolf sessions belonging to the current SSH peer."""

import json
import os
import socket
import time


SOCKET_PATH = "/run/wolf-streaming/runtime/wolf.sock"


def request(method, path, payload=None):
    body = b""
    headers = [
        f"{method} {path} HTTP/1.1",
        "Host: localhost",
        "Connection: close",
    ]
    if payload is not None:
        body = json.dumps(payload, separators=(",", ":")).encode()
        headers.extend(
            [
                "Content-Type: application/json",
                f"Content-Length: {len(body)}",
            ]
        )
    wire = ("\r\n".join(headers) + "\r\n\r\n").encode() + body

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(SOCKET_PATH)
        connection.sendall(wire)
        response = bytearray()
        while chunk := connection.recv(65536):
            response.extend(chunk)

    status_line, remainder = bytes(response).split(b"\r\n", 1)
    _headers, response_body = remainder.split(b"\r\n\r\n", 1)
    if b" 200 " not in status_line:
        raise RuntimeError(status_line.decode(errors="replace"))
    return json.loads(response_body) if response_body else {}


def peer_sessions(peer_address):
    sessions = request("GET", "/api/v1/sessions").get("sessions", [])
    return [
        session
        for session in sessions
        if session.get("client_ip") == peer_address
    ]


def main():
    ssh_connection = os.environ.get("SSH_CONNECTION", "").split()
    if not ssh_connection:
        raise SystemExit("SSH_CONNECTION is required")
    peer_address = ssh_connection[0]

    for session in peer_sessions(peer_address):
        session_id = session.get("client_id")
        if session_id:
            request(
                "POST",
                "/api/v1/sessions/stop",
                {"session_id": session_id},
            )

    deadline = time.monotonic() + 5
    while peer_sessions(peer_address):
        if time.monotonic() >= deadline:
            raise TimeoutError("Wolf did not clear the peer session")
        time.sleep(0.1)


if __name__ == "__main__":
    main()
