#!/usr/bin/env bash
set -euo pipefail

remote_url=${DMS_PLUGINS_REMOTE_URL:-https://github.com/alcxyz/dms-plugins.git}

current_rev=$(python3 -c 'import json; print(json.load(open("flake.lock"))["nodes"]["dms-plugins"]["locked"]["rev"])')
latest_rev=$(git ls-remote "$remote_url" refs/heads/main | awk '{print $1}')

echo "Current dms-plugins: $current_rev"
echo "Latest dms-plugins:  $latest_rev"

if [[ -z "$latest_rev" ]]; then
	echo "Unable to resolve dms-plugins main" >&2
	exit 1
fi

if [[ "$current_rev" == "$latest_rev" ]]; then
	echo "Already up to date — nothing to do."
	echo "updated=false" >>"$GITHUB_OUTPUT"
	exit 0
fi

nix flake update dms-plugins

updated_rev=$(python3 -c 'import json; print(json.load(open("flake.lock"))["nodes"]["dms-plugins"]["locked"]["rev"])')
if [[ "$updated_rev" != "$latest_rev" ]]; then
	echo "Lock refresh selected ${updated_rev}, expected ${latest_rev}" >&2
	exit 1
fi

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
	echo "revision=$latest_rev"
} >>"$GITHUB_OUTPUT"

printf 'Verified dms-plugins %s with DankAIUsage %s.\n' "$latest_rev" "$version"
