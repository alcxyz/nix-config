#!/usr/bin/env python3
"""Atomically reconcile selected Wolf Moonlight apps without touching private state."""

import json
import os
from pathlib import Path
import sys
import tempfile

import tomlkit


def unwrap(value):
    return value.unwrap() if hasattr(value, "unwrap") else value


def contains_values(current, desired):
    current = unwrap(current)
    if isinstance(desired, dict):
        return isinstance(current, dict) and all(
            key in current and contains_values(current[key], value)
            for key, value in desired.items()
        )
    if isinstance(desired, list):
        return isinstance(current, list) and current == desired
    return current == desired


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: reconcile-apps.py CONFIG MANAGED_APPS_JSON")

    config_path = Path(sys.argv[1])
    managed_path = Path(sys.argv[2])
    if not config_path.exists():
        return 0

    document = tomlkit.parse(config_path.read_text())
    managed = json.loads(managed_path.read_text())
    managed_apps = managed["apps"]
    managed_titles = set(managed["managedTitles"])
    profile = next(
        (
            item
            for item in document.get("profiles", [])
            if item.get("id") == "moonlight-profile-id"
        ),
        None,
    )
    if profile is None:
        raise RuntimeError("Wolf config has no moonlight-profile-id profile")

    apps = profile.setdefault("apps", tomlkit.aot())
    changed = False
    desired_titles = {app["title"] for app in managed_apps}
    for index in reversed(range(len(apps))):
        title = apps[index].get("title")
        if title in managed_titles and title not in desired_titles:
            del apps[index]
            changed = True

    for desired in managed_apps:
        index = next(
            (i for i, app in enumerate(apps) if app.get("title") == desired["title"]),
            None,
        )
        if index is None:
            apps.append(desired)
            changed = True
        elif not contains_values(apps[index], desired):
            apps[index] = desired
            changed = True

    if not changed:
        return 0

    stat = config_path.stat()
    with tempfile.NamedTemporaryFile(
        mode="w", dir=config_path.parent, prefix=".config.toml.", delete=False
    ) as handle:
        temporary_path = Path(handle.name)
        handle.write(tomlkit.dumps(document))
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
