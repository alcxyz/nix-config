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

python3 scripts/checks/test-configuration-ci.py
python3 scripts/checks/test-development-ci.py
bash scripts/checks/test-publish-wolf-images.sh
bash scripts/checks/test-xyz-runtime-storage-policy.sh hosts/xyz/xyz-runtime-storage-policy.sh
bash modules/nixos/services/storage-health-monitor/test-storage-health-monitor.sh \
  modules/nixos/services/storage-health-monitor/record-success.sh \
  modules/nixos/services/storage-health-monitor/check-recent-success.sh
