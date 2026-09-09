#!/usr/bin/env bash
set -euo pipefail

phase=${1:-all}
if (($# > 1)) || [[ $phase != all && $phase != all-systems && $phase != native ]]; then
  echo 'Usage: check-configurations.sh [all|all-systems|native]' >&2
  exit 2
fi

# Refuse lock rewrites: validate the checked-out candidate exactly as supplied.
if [[ $phase == all || $phase == all-systems ]]; then
  nix flake check --all-systems --no-build --no-update-lock-file
fi
if [[ $phase == all || $phase == native ]]; then
  nix flake check --keep-going --no-update-lock-file
fi
