#!/usr/bin/env python3
"""Describe DMS source revisions from a base lock on stdin and a candidate lock."""

import json
import sys


def source_revisions(lock):
    nodes = lock["nodes"]

    def resolve(path):
        node = lock["root"]
        for name in path:
            reference = nodes[node]["inputs"][name]
            node = resolve(reference) if isinstance(reference, list) else reference
        return node

    bundle = resolve(["dms-plugins"])
    paths = {"dms-plugins": ["dms-plugins"]}
    for name, reference in nodes[bundle]["inputs"].items():
        # A follows input uses its canonical root path, independent of node IDs.
        path = reference if isinstance(reference, list) else ["dms-plugins", name]
        paths["/".join(path)] = path
    return {
        name: nodes[resolve(path)]["locked"].get("rev")
        or nodes[resolve(path)]["locked"]["narHash"]
        for name, path in paths.items()
    }


before = source_revisions(json.load(sys.stdin))
with open(sys.argv[1], encoding="utf-8") as candidate:
    after = source_revisions(json.load(candidate))
changes = [
    f"- `{name}`: `{before.get(name, 'absent')}` -> `{after.get(name, 'absent')}`"
    for name in sorted(before.keys() | after.keys())
    if before.get(name) != after.get(name)
]
body = "Automated, build-verified refresh of DMS lock inputs.\n\nChanged inputs:\n"
body += "\n".join(changes)
body += (
    "\n\nValidation metadata: the Home Manager activation package was built "
    f"with DankAIUsage `{sys.argv[2]}`. This built version does not indicate "
    "which inputs changed."
)
print(json.dumps({"title": "chore(dms): refresh plugin lock inputs", "body": body}))
