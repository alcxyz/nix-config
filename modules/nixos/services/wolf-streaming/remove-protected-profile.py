#!/usr/bin/env python3
"""Atomically remove a migrated protected profile from a Wolf coordinator."""

import json
import os
from pathlib import Path
import sys
import tempfile

import tomlkit


def main():
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: remove-protected-profile.py CONFIG PROFILE_DEFINITION_JSON"
        )

    config_path = Path(sys.argv[1])
    definition_path = Path(sys.argv[2])
    if not config_path.exists():
        return 0

    definition = json.loads(definition_path.read_text())
    profile_id = definition.get("id")
    if not isinstance(profile_id, str) or not profile_id:
        raise ValueError("protected profile id must be a non-empty string")
    if profile_id == "moonlight-profile-id":
        raise ValueError("refusing to remove the direct Moonlight profile")

    config_text = config_path.read_text()
    if config_text and not config_text.endswith("\n"):
        config_text += "\n"
    document = tomlkit.parse(config_text)
    profiles = document.get("profiles", [])
    changed = False
    for index in reversed(range(len(profiles))):
        if profiles[index].get("id") == profile_id:
            del profiles[index]
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
