#!/usr/bin/env bash
set -euo pipefail

# Keep upstream/platform inputs untouched. Nested overrides need explicit
# updates even when the aggregate repository has not changed.
dms_only=false
list_only=false
for option in "$@"; do
  case "$option" in
    --dms-only) dms_only=true ;;
    --list) list_only=true ;;
    *)
      echo "Usage: $0 [--dms-only] [--list]" >&2
      exit 2
      ;;
  esac
done

inputs=(
  dms-plugins
  danksession
  dms-plugins/quicksearch
  dms-plugins/vault
  dms-plugins/translate
  dms-plugins/spotify
  dms-plugins/dankcalendar
  dms-plugins/diskusage
  dms-plugins/aiusage
  dms-plugins/displaycontrol
)
if ! "$dms_only"; then
  inputs+=(paperflow grove canopy)
fi

if "$list_only"; then
  printf '%s\n' "${inputs[@]}"
else
  exec nix flake update "${inputs[@]}"
fi
