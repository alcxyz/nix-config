#!/usr/bin/env python3
"""Atomically reconcile one protected Wolf profile from a runtime credential."""

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


def load_profile_definition(path):
    definition = json.loads(path.read_text())
    required = {"id", "name", "pin"}
    missing = required - definition.keys()
    if missing:
        raise ValueError(
            "protected profile definition is missing: " + ", ".join(sorted(missing))
        )
    if not isinstance(definition["id"], str) or not definition["id"]:
        raise ValueError("protected profile id must be a non-empty string")
    if definition["id"] == "moonlight-profile-id":
        raise ValueError(
            "protected profile must not replace the direct Moonlight profile"
        )
    if not isinstance(definition["name"], str) or not definition["name"]:
        raise ValueError("protected profile name must be a non-empty string")
    if not (
        isinstance(definition["pin"], list)
        and definition["pin"]
        and all(
            isinstance(digit, int) and 0 <= digit <= 9 for digit in definition["pin"]
        )
    ):
        raise ValueError("protected profile pin must be a non-empty array of digits")

    allowed = {"id", "name", "pin", "icon_png_path"}
    unexpected = definition.keys() - allowed
    if unexpected:
        raise ValueError(
            "protected profile definition has unsupported keys: "
            + ", ".join(sorted(unexpected))
        )
    return definition


def write_document(config_path, document):
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


def main():
    if len(sys.argv) != 4:
        raise SystemExit(
            "usage: reconcile-protected-profile.py CONFIG PROFILE_JSON MANAGED_APPS_JSON"
        )

    config_path = Path(sys.argv[1])
    profile_path = Path(sys.argv[2])
    managed_path = Path(sys.argv[3])
    if not config_path.exists():
        return 0

    definition = load_profile_definition(profile_path)
    managed = json.loads(managed_path.read_text())
    managed_apps = managed["apps"]
    managed_titles = set(managed["managedTitles"])
    config_text = config_path.read_text()
    if config_text and not config_text.endswith("\n"):
        config_text += "\n"
    document = tomlkit.parse(config_text)
    profiles = document.setdefault("profiles", tomlkit.aot())
    profile = next(
        (item for item in profiles if item.get("id") == definition["id"]), None
    )
    changed = False

    if profile is None:
        profile = tomlkit.table()
        for key, value in definition.items():
            profile[key] = value
        profile["apps"] = tomlkit.aot()
        profiles.append(profile)
        changed = True
    else:
        for key, value in definition.items():
            if key not in profile or not contains_values(profile[key], value):
                profile[key] = value
                changed = True

    apps = profile.setdefault("apps", tomlkit.aot())
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

    if changed:
        write_document(config_path, document)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
