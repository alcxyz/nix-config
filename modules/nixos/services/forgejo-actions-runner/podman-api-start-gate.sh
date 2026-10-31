#!/usr/bin/env bash
set -euo pipefail

# ExecCondition of both CI engine APIs. Exit 1 skips the start without a
# restart attempt. The start lock orders each API start after a Podman store
# reset's rename (ADR-0105).

state_dir=${STATE_DIR:-/run/forgejo-runner-hold}

[[ ! -L $state_dir ]] || exit 1
install -d -m 0700 "$state_dir"
[[ $(stat -c '%u:%a' -- "$state_dir") == "$EUID:700" ]] || exit 1
[[ ! -L $state_dir/start.lock ]] || exit 1
exec 9>"$state_dir/start.lock"
flock -w 60 -x 9 || exit 1
