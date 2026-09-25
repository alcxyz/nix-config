"""Merge Nix-managed kubeconfig sync paths into Freelens preferences."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


def freelens_is_running() -> bool:
    ps = shutil.which("ps")
    if ps is None:
        return True
    try:
        result = subprocess.run(
            [ps, "-ax", "-o", "comm="],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        # Refuse to mutate a possibly live store when the guard cannot run.
        return True

    return any(
        Path(command.strip()).name.lower() in {"freelens", "freelens.exe"}
        for command in result.stdout.splitlines()
    )


def read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def write_json_atomic(path: Path, value: Any, mode: int) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_path, path)
    finally:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def merge_sync_paths(
    settings: Any, previous: Any, desired: list[str]
) -> tuple[dict[str, Any], list[str]]:
    if not isinstance(settings, dict):
        raise TypeError("Freelens settings root must be a JSON object")
    if not isinstance(previous, list) or not all(
        isinstance(path, str) for path in previous
    ):
        raise ValueError("managed Freelens sync state must be a JSON string array")

    preferences = settings.setdefault("preferences", {})
    if not isinstance(preferences, dict):
        raise TypeError("Freelens preferences must be a JSON object")

    entries = preferences.get("syncKubeconfigEntries", [])
    if not isinstance(entries, list):
        raise TypeError("Freelens syncKubeconfigEntries must be a JSON array")

    previous_set = set(previous)
    merged: list[dict[str, str]] = []
    seen: set[str] = set()
    user_paths: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("filePath"), str):
            raise TypeError(
                "each Freelens kubeconfig sync entry must contain a string filePath"
            )
        file_path = entry["filePath"]
        if file_path in previous_set or file_path in seen:
            continue
        merged.append(entry)
        seen.add(file_path)
        user_paths.add(file_path)

    owned: list[str] = []
    for file_path in dict.fromkeys(desired):
        if file_path not in seen:
            merged.append({"filePath": file_path})
            seen.add(file_path)
        if file_path in previous_set or file_path not in user_paths:
            owned.append(file_path)

    preferences["syncKubeconfigEntries"] = merged
    return settings, owned


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(
            "usage: freelens-kubeconfig-sync SETTINGS MANAGED_STATE [KUBECONFIG_PATH ...]",
            file=sys.stderr,
        )
        return 2

    settings_path = Path(argv[1])
    state_path = Path(argv[2])
    desired = list(dict.fromkeys(argv[3:]))

    if freelens_is_running():
        print(
            "Freelens is running (or its process state could not be checked); "
            "leaving its settings unchanged. Quit Freelens and run "
            "freelens-kubeconfig-sync.",
            file=sys.stderr,
        )
        return 0

    try:
        settings = read_json(settings_path, {})
        previous = read_json(state_path, [])
        merged, owned = merge_sync_paths(settings, previous, desired)
        settings_mode = (
            settings_path.stat().st_mode & 0o777 if settings_path.exists() else 0o600
        )
        write_json_atomic(settings_path, merged, settings_mode)
        write_json_atomic(state_path, owned, 0o600)
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(
            f"could not update Freelens kubeconfig sync settings: {error}",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
