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
  scripts/forgejo/publish-dms-plugins-lock.sh \
  scripts/forgejo/merge-dms-plugins-lock.sh \
  scripts/ops/*.sh \
  scripts/update-inputs/lock-promoted-packages.sh \
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
# Check the tea module's script bodies with the bindings default.nix puts
# before them; each body uses only some of them.
for body in tea-with-token-file ensure-login; do
  {
    printf '%s\n' tea_bin=tea tea_url=url tea_login=login tea_ssh_host=host tea_config_home=.config
    cat "modules/home-manager/programs/tea/$body.sh"
  } | shellcheck --shell=bash --exclude=SC2034 -
done

python3 scripts/checks/test-configuration-ci.py
python3 scripts/checks/test-commit-status.py
python3 scripts/checks/test-publish-dms-plugins-lock.py
python3 scripts/checks/test-merge-dms-plugins-lock.py
python3 scripts/checks/test-development-ci.py
python3 scripts/checks/test-first-timer-freshness.py
python3 scripts/checks/test-podman-canary-logs.py
python3 scripts/checks/test-local-package-promotion.py
python3 scripts/checks/test-lock-promoted-packages.py
python3 scripts/checks/test-wolf-context-package.py
python3 scripts/checks/check-moonlight-shell-templates.py
python3 scripts/checks/check-wolf-shell-templates.py
bash scripts/checks/test-publish-wolf-images.sh
bash scripts/checks/test-xyz-runtime-storage-policy.sh hosts/xyz/xyz-runtime-storage-policy.sh
bash modules/nixos/services/storage-health-monitor/test-storage-health-monitor.sh \
  modules/nixos/services/storage-health-monitor/record-success.sh \
  modules/nixos/services/storage-health-monitor/check-recent-success.sh \
  modules/nixos/services/storage-health-monitor/check-active-unit.sh

python3 flake/checks/test-forgejo-runner-hold.py \
  modules/nixos/services/forgejo-actions-runner/runner-hold.sh \
  modules/nixos/services/forgejo-actions-runner/runner-start-gate.sh \
  modules/nixos/services/game-signal/game-signal.sh
python3 flake/checks/test-forgejo-podman-store-reset.py \
  modules/nixos/services/forgejo-actions-runner/podman-store-reset.sh
