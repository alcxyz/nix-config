#!/usr/bin/env bash
set -euo pipefail

# Refresh the owner's released apps. Each input follows its repository's
# `main` branch; activation stays explicit (ADR-0089).
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
)

if "$list_only"; then
  printf '%s\n' "${inputs[@]}"
else
  exec nix flake update "${inputs[@]}"
fi
