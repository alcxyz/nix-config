#!/usr/bin/env python3
"""Move KDE Connect's XTest-only pointer events into Hyprland."""

import glob
import json
import os
import re
import socket
import subprocess
import time


runtime_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
kdeconnect_socket_path = os.path.join(
    runtime_dir, "kdeconnect-hypr-pointer.sock"
)
xrandr_output = re.compile(
    r"^(\S+) connected(?: primary)? (\d+)x(\d+)\+(-?\d+)\+(-?\d+)"
)


def hypr_request(command):
    signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    preferred = (
        os.path.join(runtime_dir, "hypr", signature, ".socket.sock")
        if signature
        else None
    )
    candidates = glob.glob(os.path.join(runtime_dir, "hypr", "*", ".socket.sock"))
    candidates.sort(key=lambda path: os.path.getmtime(path), reverse=True)
    if preferred in candidates:
        candidates.remove(preferred)
        candidates.insert(0, preferred)

    for hypr_socket in candidates:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(0.25)
                client.connect(hypr_socket)
                client.sendall(command.encode())
                response = bytearray()
                while True:
                    chunk = client.recv(65536)
                    if not chunk:
                        break
                    response.extend(chunk)
                return response.decode()
        except (OSError, UnicodeDecodeError):
            continue
    return ""


def monitor_mapping():
    try:
        xrandr = subprocess.run(
            ["xrandr", "--query"],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2,
        ).stdout
        hypr = json.loads(hypr_request("j/monitors all") or "[]")
    except (json.JSONDecodeError, OSError, subprocess.SubprocessError):
        return []

    x_outputs = {}
    for line in xrandr.splitlines():
        match = xrandr_output.match(line)
        if match:
            name, width, height, x, y = match.groups()
            x_outputs[name] = tuple(map(int, (x, y, width, height)))

    mapping = []
    for monitor in hypr:
        source = x_outputs.get(monitor.get("name"))
        scale = float(monitor.get("scale") or 1)
        if source is None or scale <= 0:
            continue
        mapping.append(
            (
                source,
                (
                    int(monitor.get("x", 0)),
                    int(monitor.get("y", 0)),
                    round(int(monitor.get("width", 0)) / scale),
                    round(int(monitor.get("height", 0)) / scale),
                ),
            )
        )
    return mapping


def translate(x, y, mapping):
    for (source_x, source_y, source_width, source_height), (
        target_x,
        target_y,
        target_width,
        target_height,
    ) in mapping:
        if (
            source_width > 0
            and source_height > 0
            and source_x <= x < source_x + source_width
            and source_y <= y < source_y + source_height
        ):
            local_x = (x - source_x) / source_width
            local_y = (y - source_y) / source_height
            return (
                round(target_x + local_x * target_width),
                round(target_y + local_y * target_height),
            )
    return None


try:
    os.unlink(kdeconnect_socket_path)
except FileNotFoundError:
    pass
kdeconnect_socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
kdeconnect_socket.bind(kdeconnect_socket_path)
os.chmod(kdeconnect_socket_path, 0o600)
kdeconnect_socket.setblocking(False)
mapping = []
mapping_updated_at = 0.0

while True:
    now = time.monotonic()
    if now - mapping_updated_at >= 2:
        mapping = monitor_mapping()
        mapping_updated_at = now

    while True:
        try:
            message = kdeconnect_socket.recv(96).decode().split()
        except BlockingIOError:
            break
        except (OSError, UnicodeDecodeError):
            continue

        try:
            kind, first, second = message
            first = float(first)
            second = float(second)
        except (ValueError, TypeError):
            continue

        if kind == "M":
            try:
                current = json.loads(hypr_request("j/cursorpos") or "{}")
                target = (
                    round(float(current["x"]) + first),
                    round(float(current["y"]) + second),
                )
            except (json.JSONDecodeError, KeyError, TypeError, ValueError):
                continue
        elif kind == "A":
            target = translate(first, second, mapping)
            if target is None:
                continue
        else:
            continue
        hypr_request(f"dispatch movecursor {target[0]} {target[1]}")

    time.sleep(1 / 60)
