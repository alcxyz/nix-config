#!/usr/bin/env bash

# Toggle focus to/from the named "scratch" workspace in niri.
# If currently on the scratch workspace, jump back to the previous one.
# Otherwise, switch to the scratch workspace.

SCRATCH="scratch"
CURRENT=$(niri msg -j workspaces | jq -r '.[] | select(.is_focused) | .name // empty')

if [ "$CURRENT" = "$SCRATCH" ]; then
    niri msg action focus-workspace-previous
else
    niri msg action focus-workspace "$SCRATCH"
fi
