#!/usr/bin/env python3
"""Syntax-check the Moonlight input source templates with optional blocks."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
SOURCE_DIRECTORY = ROOT / "modules/nixos/services/moonlight-client"
MARKER = re.compile(r"@[A-Za-z][A-Za-z0-9]*@")


def render(template_name, common, optional, enabled):
    source = (SOURCE_DIRECTORY / template_name).read_text()
    replacements = common | {
        name: value if enabled else "    \n" for name, value in optional.items()
    }
    for name, value in replacements.items():
        source = source.replace(f"@{name}@", value)
    unresolved = sorted(set(MARKER.findall(source)))
    assert not unresolved, (template_name, unresolved)
    compile(source, template_name, "exec")


controller_common = {
    "controllerDeviceName": '"Fixture Controller"',
    "controllerHoldSeconds": "1.0",
    "couchStreamControl": "/bin/true",
    "couchControlHelp": "/bin/true",
    "displayMirrorToggle": "/bin/true",
    "displayLayoutControl": "/bin/true",
    "audioOutputControl": "/bin/true",
}
controller_optional = {
    "controllerRemoteBrowserAction": '    "remote_browser": {ecodes.BTN_MODE, ecodes.BTN_NORTH},\n\n',
    "controllerBrowserAction": '    "browser": {ecodes.BTN_THUMBL, ecodes.BTN_THUMBR},\n\n',
    "controllerHelpAction": '    "help": {ecodes.BTN_SELECT, ecodes.BTN_SOUTH},\n\n',
    "controllerMirrorAction": '    "mirror": {ecodes.BTN_SELECT, ecodes.BTN_START},\n\n',
    "controllerLayoutAction": '    "layout": {ecodes.BTN_SELECT, ecodes.BTN_NORTH},\n\n',
    "controllerAudioAction": '    "audio": {ecodes.BTN_SELECT, ecodes.BTN_WEST},\n\n',
    "controllerRemoteBrowserCommand": '    "remote_browser": ["/bin/true", "remote-browser"],\n\n',
    "controllerBrowserCommand": '    "browser": ["/bin/true", "browser"],\n\n',
    "controllerHelpCommand": '    "help": ["/bin/true"],\n\n',
    "controllerMirrorCommand": '    "mirror": ["/bin/true", "toggle"],\n\n',
    "controllerLayoutCommand": '    "layout": ["/bin/true", "cycle"],\n\n',
    "controllerAudioCommand": '    "audio": ["/bin/true", "cycle"],\n\n',
}

direct_common = {
    "modeStateFile": '"/tmp/session-mode"',
    "controllerDeviceName": '"Fixture Controller"',
    "controllerHoldSeconds": "1.0",
    "kdeConnectDirectInput": "True",
    "sessionMode": "/bin/true",
}
direct_optional = {
    "directBrowserCommand": '    "direct-browser": ["/bin/true", "direct-browser"],\n\n',
    "directStreamCommand": '    "direct-stream": ["/bin/true", "direct-stream"],\n\n',
    "directPrivateCommand": '    "direct-private": ["/bin/true", "direct-private"],\n\n',
    "directPrivateKeyboardAction": '    if shift and ecodes.KEY_R in pressed:\n        return "direct-private"\n\n',
    "directBrowserKeyboardAction": '    if not shift and ecodes.KEY_R in pressed:\n        return "direct-browser"\n\n',
    "directStreamKeyboardAction": '    if not shift and ecodes.KEY_M in pressed:\n        return "direct-stream"\n\n',
    "directPrivateControllerAction": '    if (\n        state["hat_up"]\n        and ecodes.BTN_START in pressed\n        and ecodes.BTN_TR in pressed\n    ):\n        return "direct-private"\n\n',
    "directBrowserControllerAction": '    if ecodes.BTN_MODE in pressed and ecodes.BTN_NORTH in pressed:\n        return "direct-browser"\n\n',
    "directStreamControllerAction": '    if ecodes.BTN_MODE in pressed and ecodes.BTN_EAST in pressed:\n        return "direct-stream"\n\n',
}

for include_optional in (False, True):
    render(
        "controller-daemon.py.in",
        controller_common,
        controller_optional,
        include_optional,
    )
    render(
        "direct-input-daemon.py.in",
        direct_common,
        direct_optional,
        include_optional,
    )

print("Moonlight input Python source templates: PASS")
