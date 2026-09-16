#!/usr/bin/env python3
"""Check rendered Wolf shell syntax without running Docker or changing input."""
from pathlib import Path
import re
import shlex
import subprocess

SOURCES = Path(__file__).resolve().parents[2] / "modules/nixos/services/wolf-streaming"


def check(name, values):
    text = (SOURCES / name).read_text()
    markers = set(re.findall(r"@[A-Za-z]+@", text))
    assert markers == set(values), (name, markers.symmetric_difference(values))
    text = re.sub(r"@[A-Za-z]+@", lambda match: values[match[0]], text)
    subprocess.run(["bash", "-n"], input=text, text=True, check=True)
    subprocess.run(["shellcheck", "--shell=bash", "-"], input=text, text=True, check=True)


for layouts in [["no", "us"], ["us", "no", "de"], ["us"]]:
    check("stream-layout.sh.in", {
        "@runtimeDirectory@": shlex.quote("/tmp/runtime 'with spaces'"),
        "@layoutCases@": "\n".join(f"{layout}) layout_index={index} ;;" for index, layout in enumerate(layouts)),
        "@layoutChoices@": "|".join(layouts),
        "@runUid@": "1234",
        "@presentationHelper@": "/nix/store/fixture-presentation.py",
    })
check("worker-stream-layout.sh.in", {"@runtimeRoot@": "/run/fixture-worker"})
print("Wolf shell templates: 4 syntax/lint fixtures passed")
