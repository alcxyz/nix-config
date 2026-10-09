#!/usr/bin/env bash
set -euo pipefail

# Refresh the dev builds installed next to the released tools. Each input
# follows its repository's `dev` branch; activation stays explicit (ADR-0087).
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
  paperless-tools-dev
  regnskap-dev
)

if "$list_only"; then
  printf '%s\n' "${inputs[@]}"
else
  exec nix flake update "${inputs[@]}"
fi
