#!/usr/bin/env bash
set -euo pipefail

# Refresh the owner's released apps. Each input follows its repository's
# `main` branch, except the private work flake (`work`), which follows `dev`
# and is shared with
# dev-apps-update so its configuration stays current (ADR-0089). Activation
# stays explicit.
list_only=false
for option in "$@"; do
  case "$option" in
    --list) list_only=true ;;
    *)
      echo "Usage: $0 [--list]" >&2
      exit 2
      ;;
  esac
done

inputs=(
  grove
  canopy
  bivrost
  work
)

if "$list_only"; then
  printf '%s\n' "${inputs[@]}"
else
  exec nix flake update "${inputs[@]}"
fi
