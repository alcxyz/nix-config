#!/usr/bin/env bash
set -euo pipefail

if container-netns-audit >/dev/null 2>&1; then
  exit 0
fi

system_state="$(systemctl is-system-running 2>/dev/null || true)"
if [[ $system_state != starting ]]; then
  echo "refusing to change /run/netns after system startup; install this generation for boot and reboot" >&2
  exit 1
fi

for runtime in docker.service k3s.service; do
  if systemctl is-active --quiet "$runtime"; then
    echo "refusing to change /run/netns while $runtime is active" >&2
    exit 1
  fi
done

install -d -m 0755 /run/netns
exec 9</run/netns
flock --exclusive 9

for runtime in docker.service k3s.service; do
  if systemctl is-active --quiet "$runtime"; then
    echo "refusing to change /run/netns while $runtime is active" >&2
    exit 1
  fi
done

if ! mountpoint --quiet /run/netns; then
  mount --rbind /run/netns /run/netns
fi
# A self-bind below a shared /run initially joins the ancestor's peer group.
# Detach the complete bind tree before making it shared so future namespace
# mounts propagate within /run/netns without also appearing below /run.
mount --make-rprivate /run/netns
mount --make-rshared /run/netns
container-netns-audit
