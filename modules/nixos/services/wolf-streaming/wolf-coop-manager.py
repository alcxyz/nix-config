#!/usr/bin/env python3
"""Route a direct Moonlight catalog entry into one shared Wolf lobby."""

import argparse
import copy
import json
import logging
import socket
import time


class WolfApiError(RuntimeError):
    pass


class WolfApi:
    def __init__(self, socket_path):
        self.socket_path = socket_path

    def request(self, method, path, payload=None):
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
        request = ("\r\n".join(headers) + "\r\n\r\n").encode() + body

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(30)
            connection.connect(self.socket_path)
            connection.sendall(request)
            response = bytearray()
            while chunk := connection.recv(65536):
                response.extend(chunk)

        try:
            status_line, remainder = bytes(response).split(b"\r\n", 1)
            _headers, response_body = remainder.split(b"\r\n\r\n", 1)
            status = int(status_line.split()[1])
            decoded = json.loads(response_body) if response_body else {}
        except (IndexError, ValueError, json.JSONDecodeError) as error:
            raise WolfApiError("invalid response from Wolf") from error

        if status < 200 or status >= 300:
            message = decoded.get("error", f"HTTP {status}")
            raise WolfApiError(message)
        return decoded

    def get(self, path):
        return self.request("GET", path)

    def post(self, path, payload):
        return self.request("POST", path, payload)


def find_app(apps, title):
    return next((app for app in apps if app.get("title") == title), None)


def cooperative_runner(individual_app, runner_name, kdeconnect_executable):
    runner = copy.deepcopy(individual_app["runner"])
    runner["name"] = runner_name

    environment = [
        item
        for item in runner.get("env", [])
        if not item.startswith("NIXBOX_KDECONNECT_EXECUTABLE=")
    ]
    if kdeconnect_executable:
        environment.append(
            f"NIXBOX_KDECONNECT_EXECUTABLE={kdeconnect_executable}"
        )
    runner["env"] = environment

    ports = [
        item
        for item in runner.get("ports", [])
        if item not in ("1716:1716", "1716:1716:tcp", "1716:1716:udp")
    ]
    if kdeconnect_executable:
        ports.extend(["1716:1716:tcp", "1716:1716:udp"])
    runner["ports"] = ports

    create_options = json.loads(runner.get("base_create_json") or "{}")
    create_options["Hostname"] = "helium"
    runner["base_create_json"] = json.dumps(
        create_options, separators=(",", ":"), sort_keys=True
    )
    return runner


def create_lobby_payload(
    session,
    individual_app,
    lobby_name,
    runner_name,
    runner_state_folder,
    kdeconnect_executable,
    video_producer_buffer_caps,
):
    render_node = individual_app["render_node"]
    return {
        "profile_id": "moonlight-profile-id",
        "name": lobby_name,
        "icon_png_path": individual_app.get("icon_png_path"),
        "multi_user": True,
        "stop_when_everyone_leaves": False,
        "video_settings": {
            "width": session["video_width"],
            "height": session["video_height"],
            "refresh_rate": session["video_refresh_rate"],
            "wayland_render_node": render_node,
            "runner_render_node": render_node,
            "video_producer_buffer_caps": video_producer_buffer_caps,
        },
        "audio_settings": {
            "channel_count": session["audio_channel_count"],
        },
        "client_settings": session.get("client_settings"),
        "runner_state_folder": runner_state_folder,
        "runner": cooperative_runner(
            individual_app, runner_name, kdeconnect_executable
        ),
    }


def matching_lobby(lobbies, lobby_name, runner_name):
    return next(
        (
            lobby
            for lobby in lobbies
            if lobby.get("name") == lobby_name
            and lobby.get("multi_user") is True
            and (lobby.get("runner") or {}).get("name") == runner_name
        ),
        None,
    )


def reconcile_once(api, args):
    apps = api.get("/api/v1/apps").get("apps", [])
    entry_app = find_app(apps, args.entry_title)
    individual_app = find_app(apps, args.individual_title)
    if entry_app is None or individual_app is None:
        return

    sessions = api.get("/api/v1/sessions").get("sessions", [])
    entry_sessions = [
        session for session in sessions if session.get("app_id") == entry_app["id"]
    ]
    if not entry_sessions:
        return

    lobbies = api.get("/api/v1/lobbies").get("lobbies", [])
    connected_sessions = {
        session_id
        for lobby in lobbies
        for session_id in lobby.get("connected_sessions", [])
    }
    lobby = matching_lobby(lobbies, args.lobby_name, args.runner_name)

    for session in entry_sessions:
        session_id = session.get("client_id")
        if not session_id or session_id in connected_sessions:
            continue

        if lobby is None:
            payload = create_lobby_payload(
                session,
                individual_app,
                args.lobby_name,
                args.runner_name,
                args.runner_state_folder,
                args.kdeconnect_executable,
                args.video_producer_buffer_caps,
            )
            result = api.post("/api/v1/lobbies/create", payload)
            lobby = {
                "id": result["lobby_id"],
                "name": args.lobby_name,
                "multi_user": True,
                "runner": {"name": args.runner_name},
                "connected_sessions": [],
            }
            logging.info("created the shared %s lobby", args.lobby_name)

        api.post(
            "/api/v1/lobbies/join",
            {
                "lobby_id": lobby["id"],
                "moonlight_session_id": session_id,
            },
        )
        connected_sessions.add(session_id)
        logging.info("joined a Moonlight session to the shared %s lobby", args.lobby_name)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--entry-title", required=True)
    parser.add_argument("--individual-title", required=True)
    parser.add_argument("--lobby-name", required=True)
    parser.add_argument("--runner-name", required=True)
    parser.add_argument("--runner-state-folder", required=True)
    parser.add_argument("--kdeconnect-executable", default="")
    parser.add_argument("--video-producer-buffer-caps", required=True)
    parser.add_argument("--poll-seconds", type=float, default=0.5)
    return parser.parse_args()


def main():
    args = parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    api = WolfApi(args.socket)
    last_error = None

    while True:
        try:
            reconcile_once(api, args)
            last_error = None
            time.sleep(args.poll_seconds)
        except (OSError, WolfApiError, KeyError, TypeError, ValueError) as error:
            message = str(error)
            if message != last_error:
                logging.warning("waiting for Wolf lobby reconciliation: %s", message)
                last_error = message
            time.sleep(max(args.poll_seconds, 2.0))


if __name__ == "__main__":
    main()
