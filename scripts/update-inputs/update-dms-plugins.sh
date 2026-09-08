#!/usr/bin/env bash
set -euo pipefail

lock_before=$(mktemp)
trap 'rm -f "$lock_before"' EXIT
cp flake.lock "$lock_before"
output_file=${GITHUB_OUTPUT:-/dev/stdout}

# Always refresh nested dev sources: the bundle revision can stay unchanged
# while a plugin receives a new integration commit.
bash scripts/update-inputs/update-maintained.sh --dms-only

if cmp -s "$lock_before" flake.lock; then
  echo "Already up to date — nothing to do."
  echo "updated=false" >>"$output_file"
  exit 0
fi

updated_rev=$(python3 -c 'import json; print(json.load(open("flake.lock"))["nodes"]["dms-plugins"]["locked"]["rev"])')

nix flake check --no-build
package_name=$(nix eval --json .#homeConfigurations.alc-xyz.config.home.packages \
  --apply 'xs: map (x: x.name or "") xs' |
  jq -r '.[] | select(startswith("dankaiusage-"))' | head -n1)

if [[ -z "$package_name" ]]; then
  echo "Updated Home Manager configuration does not contain dankaiusage" >&2
  exit 1
fi

nix build .#homeConfigurations.alc-xyz.activationPackage --no-link
version=${package_name#dankaiusage-}

{
  echo "updated=true"
  echo "version=$version"
  echo "revision=$updated_rev"
} >>"$output_file"

printf 'Verified DMS dev pins (bundle %s, DankAIUsage %s).\n' "$updated_rev" "$version"
