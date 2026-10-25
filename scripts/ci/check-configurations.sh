#!/usr/bin/env bash
set -euo pipefail

phase=${1:-all}
if (($# > 1)) || [[ $phase != all && $phase != all-systems && $phase != native ]]; then
  echo 'Usage: check-configurations.sh [all|all-systems|native]' >&2
  exit 2
fi

# Refuse lock rewrites: validate the checked-out candidate exactly as supplied.
# The native phase runs first. `--no-build` evaluates read-only, so it never
# copies a source path into the store, and reading a copy that garbage
# collection removed fails with "path ... is not valid". The native phase
# evaluates normally and restores such copies before the read-only phase.
if [[ $phase == all || $phase == native ]]; then
  native_args=(--keep-going --no-update-lock-file)
  # Optional out-link prefix that GC-roots the built check results.
  if [[ -n ${CHECK_RESULTS_OUT_LINK:-} ]]; then
    native_args+=(--out-link "$CHECK_RESULTS_OUT_LINK")
  fi
  nix flake check "${native_args[@]}"
fi
if [[ $phase == all || $phase == all-systems ]]; then
  nix flake check --all-systems --no-build --no-update-lock-file
fi
