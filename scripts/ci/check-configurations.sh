#!/usr/bin/env bash
set -euo pipefail

# Refuse lock rewrites: validate the checked-out candidate exactly as supplied.
nix flake check --all-systems --no-build --no-update-lock-file
nix flake check --keep-going --no-update-lock-file
