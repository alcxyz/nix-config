#!/usr/bin/env python3
"""Atomically enforce an explicit endpoint policy for one Moonlight host."""

import ipaddress
import os
from pathlib import Path
import re
import socket
import sys
import tempfile


RFC1918 = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
)


def resolve_address(value):
    try:
        return ipaddress.ip_address(value)
    except ValueError:
        candidates = []
        try:
            answers = socket.getaddrinfo(value, None, type=socket.SOCK_STREAM)
        except socket.gaierror as error:
            raise ValueError(f"unable to resolve Moonlight endpoint {value!r}") from error
        for _family, _type, _protocol, _canonical_name, sockaddr in answers:
            candidate = ipaddress.ip_address(sockaddr[0].split("%", 1)[0])
            if candidate not in candidates:
                candidates.append(candidate)
        if not candidates:
            raise ValueError(f"Moonlight endpoint {value!r} resolved to no addresses")
        return next(
            (candidate for candidate in candidates if candidate.version == 4),
            candidates[0],
        )


def main():
    if len(sys.argv) not in (6, 8):
        raise SystemExit(
            "usage: reconcile-endpoints.py CONFIG HOSTNAME MODE LAN_ADDRESS "
            "REMOTE_ADDRESS [HTTP_PORT PREVIOUS_HOSTNAME]"
        )

    config_path = Path(sys.argv[1])
    hostname = sys.argv[2]
    mode = sys.argv[3]
    lan_address = resolve_address(sys.argv[4])
    remote_address = resolve_address(sys.argv[5])
    http_port = int(sys.argv[6]) if len(sys.argv) == 8 and sys.argv[6] else None
    previous_hostname = sys.argv[7] if len(sys.argv) == 8 else ""
    if http_port is not None and not 1 <= http_port <= 65535:
        raise ValueError("Moonlight HTTP port must be between 1 and 65535")

    if mode not in ("lan-only", "lan-first", "remote-only"):
        raise ValueError(f"unsupported Moonlight endpoint mode: {mode!r}")

    if not isinstance(lan_address, ipaddress.IPv4Address) or not any(
        lan_address in network for network in RFC1918
    ):
        raise ValueError("Moonlight LAN address must be RFC 1918 IPv4")
    if mode == "lan-first" and lan_address == remote_address:
        raise ValueError("Moonlight LAN and remote addresses must differ")
    if not config_path.exists():
        return 0

    lines = config_path.read_text().splitlines(keepends=True)
    in_hosts = False
    host_index = None
    previous_host_index = None
    for line in lines:
        stripped = line.rstrip("\r\n")
        if stripped.startswith("[") and stripped.endswith("]"):
            in_hosts = stripped == "[hosts]"
            continue
        if not in_hosts:
            continue
        match = re.fullmatch(r"(\d+)\\hostname=(.*)", stripped)
        if match:
            if match.group(2) == hostname:
                host_index = match.group(1)
                break
            if previous_hostname and match.group(2) == previous_hostname:
                previous_host_index = match.group(1)

    if host_index is None:
        host_index = previous_host_index
    if host_index is None:
        raise RuntimeError(
            f"Moonlight has no paired host named {hostname!r}"
            + (
                f" or migration source {previous_hostname!r}"
                if previous_hostname
                else ""
            )
        )

    preferred_address = remote_address if mode == "remote-only" else lan_address
    desired = {
        f"{host_index}\\hostname": hostname,
        f"{host_index}\\localaddress": str(preferred_address),
        f"{host_index}\\manualaddress": str(preferred_address),
        f"{host_index}\\remoteaddress": str(
            remote_address if mode == "lan-first" else preferred_address
        ),
    }
    if http_port is not None:
        desired.update(
            {
                f"{host_index}\\localport": str(http_port),
                f"{host_index}\\manualport": str(http_port),
                f"{host_index}\\remoteport": str(http_port),
            }
        )
    found = set()
    changed = False
    output = []
    in_hosts = False
    for line in lines:
        stripped = line.rstrip("\r\n")
        newline = line[len(stripped) :]
        if stripped.startswith("[") and stripped.endswith("]"):
            if in_hosts:
                for key, value in desired.items():
                    if key not in found:
                        output.append(f"{key}={value}\n")
                        changed = True
            in_hosts = stripped == "[hosts]"
        if in_hosts and "=" in stripped:
            key, current = stripped.split("=", 1)
            if key in desired:
                found.add(key)
                value = desired[key]
                if current != value:
                    line = f"{key}={value}{newline or chr(10)}"
                    changed = True
        output.append(line)

    if in_hosts:
        for key, value in desired.items():
            if key not in found:
                output.append(f"{key}={value}\n")
                changed = True

    if not changed:
        return 0

    stat = config_path.stat()
    with tempfile.NamedTemporaryFile(
        mode="w", dir=config_path.parent, prefix=".Moonlight.conf.", delete=False
    ) as handle:
        temporary_path = Path(handle.name)
        handle.writelines(output)
        handle.flush()
        os.fsync(handle.fileno())

    try:
        os.chmod(temporary_path, stat.st_mode)
        os.chown(temporary_path, stat.st_uid, stat.st_gid)
        os.replace(temporary_path, config_path)
        directory_fd = os.open(config_path.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary_path.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
