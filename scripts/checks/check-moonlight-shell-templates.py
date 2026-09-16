#!/usr/bin/env python3
"""Lint rendered shell templates with synthetic inputs; never execute them."""
import itertools
from pathlib import Path
import re
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "modules/nixos/services/moonlight-client"


def check(name, values):
    text = (SOURCES / name).read_text()
    markers = set(re.findall(r"@[A-Za-z]+@", text))
    assert markers == set(values), (name, markers.symmetric_difference(values))
    # Match Nix replaceStrings: replacement text is not substituted again.
    text = re.sub(r"@[A-Za-z]+@", lambda match: values[match[0]], text)
    subprocess.run(["bash", "-n"], input=text, text=True, check=True)
    subprocess.run(["shellcheck", "--shell=bash", "-"], input=text, text=True, check=True)


for desktop, merged in itertools.product(["", " | desktop"], ["", " | merged"]):
    check("compositor-session-condition.sh.in", {
        "@modeStateFile@": shlex.quote("/tmp/mode 'file'"),
        "@desktopMode@": desktop,
        "@mergedMode@": merged,
    })

for directory in ["/tmp/profile", "/tmp/profile 'with spaces'"]:
    check("moonlight-profile.sh.in", {
        "@configDirectory@": shlex.quote(directory + "/config"),
        "@cacheDirectory@": shlex.quote(directory + "/cache"),
        "@dataDirectory@": shlex.quote(directory + "/data"),
        "@moonlightExecutable@": "/nix/store/fixture-moonlight/bin/moonlight",
    })

for cases in ["", "*'keyboard'*) printf '%s\\n' no; exit 0 ;;\n*'other'*) printf '%s\\n' us; exit 0 ;;"]:
    check("active-keyboard-layout.sh.in", {
        "@configuredLayouts@": shlex.quote("no,us"),
        "@deviceLayoutCases@": cases,
    })

print("Moonlight shell templates: 8 syntax/lint fixtures passed")
