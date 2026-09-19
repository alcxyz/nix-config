#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
  echo 'Usage: check-development.sh BASE_REVISION' >&2
  exit 2
fi

base_revision=$1
git cat-file -e "${base_revision}^{commit}"
git diff --check "$base_revision" HEAD
bash scripts/checks/forbid-submodules.sh

treefmt --ci --formatters nix
treefmt --ci --formatters shell

shellcheck \
  scripts/checks/*.sh \
  scripts/ci/*.sh \
  scripts/forgejo/publish-nix-packages-lock.sh \
  scripts/ops/*.sh \
  modules/nixos/services/storage-health-monitor/*.sh \
  modules/nixos/services/wolf-streaming/browser-image/*.sh
shellcheck --shell=bash hosts/xyz/xyz-*.sh
# The display fragment receives target_spec and leaves external_seen for its caller.
shellcheck --shell=bash --exclude=SC2154,SC2034 modules/nixos/services/moonlight-client/display-mode.sh
shellcheck --shell=bash modules/nixos/services/moonlight-client/hdmi-audio.sh
shellcheck --shell=bash users/alc/linux/xyz/desktop-scripts/{mail-workspace,close-active-window,xwayland-primary-output,dropterm-toggle}.sh
# Check the guard with its Nix-supplied policy binding; do not execute it.
{
  printf '%s\n' 'policies=[]'
  cat users/alc/linux/xyz/desktop-scripts/game-window-geometry-guard.sh
} | shellcheck --shell=bash -

python3 scripts/checks/test-configuration-ci.py
python3 scripts/checks/test-commit-status.py
python3 scripts/checks/test-development-ci.py
python3 scripts/checks/test-local-package-promotion.py
python3 scripts/checks/check-moonlight-shell-templates.py
python3 scripts/checks/check-wolf-shell-templates.py
bash scripts/checks/test-publish-wolf-images.sh
bash scripts/checks/test-xyz-runtime-storage-policy.sh hosts/xyz/xyz-runtime-storage-policy.sh
bash modules/nixos/services/storage-health-monitor/test-storage-health-monitor.sh \
  modules/nixos/services/storage-health-monitor/record-success.sh \
  modules/nixos/services/storage-health-monitor/check-recent-success.sh \
  modules/nixos/services/storage-health-monitor/check-active-unit.sh
