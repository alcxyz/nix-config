import json
import socket
import sys

session_or_lobby_id, scale = sys.argv[1:]

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
        connection.connect("/run/wolf-streaming/runtime/wolf.sock")
        connection.sendall(wire)
        response = bytearray()
        while chunk := connection.recv(65536):
            response.extend(chunk)

    status_line, remainder = bytes(response).split(b"\r\n", 1)
    _headers, response_body = remainder.split(b"\r\n\r\n", 1)
    if b" 200 " not in status_line:
        raise RuntimeError(status_line.decode(errors="replace"))
    return json.loads(response_body) if response_body else {}

client_id = session_or_lobby_id
if not client_id.isdecimal():
    lobbies = request("GET", "/api/v1/lobbies").get("lobbies", [])
    lobby = next(
        (item for item in lobbies if item.get("id") == session_or_lobby_id),
        None,
    )
    connected_sessions = (
        lobby.get("connected_sessions", []) if lobby is not None else []
    )
    if not connected_sessions:
        raise SystemExit(0)
    client_id = connected_sessions[-1]

request(
    "POST",
    "/api/v1/clients/settings",
    {
        "client_id": client_id,
        "settings": {"presentation_scale": float(scale)},
    },
)
