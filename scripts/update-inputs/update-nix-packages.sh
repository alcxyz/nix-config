#!/usr/bin/env bash
set -euo pipefail

lock_file=flake.lock
remote_url=${NIX_PACKAGES_REMOTE_URL:-https://git.alc.xyz/alcxyz/nix-packages.git}
queue_api_url=${NIX_PACKAGES_QUEUE_API_URL:-https://git.alc.xyz/api/v1/repos/alcxyz/nix-packages/pulls?state=open\&base=dev\&limit=100}

queue_json=$(curl -fsSL "$queue_api_url")
readarray -t pending_updates < <(
  jq -r '.[] | select(.head.ref | startswith("update/")) | "#\(.number // .index) \(.head.ref): \(.title)"' <<<"$queue_json"
)
if ((${#pending_updates[@]} > 0)); then
  echo "Deferring nix-packages lock refresh while package updates remain open:"
  printf '  %s\n' "${pending_updates[@]}"
  echo "updated=false" >>"$GITHUB_OUTPUT"
  exit 0
fi

current_rev=$(python3 -c 'import json; print(json.load(open("flake.lock"))["nodes"]["nix-packages"]["locked"]["rev"])')
latest_rev=$(git ls-remote "$remote_url" refs/heads/dev | awk '{print $1}')

echo "Current nix-packages: $current_rev"
echo "Latest nix-packages:  $latest_rev"

if [[ -z "$latest_rev" ]]; then
  echo "Unable to resolve nix-packages dev" >&2
  exit 1
fi

if [[ "$current_rev" == "$latest_rev" ]]; then
  echo "Already up to date — nothing to do."
  echo "updated=false" >>"$GITHUB_OUTPUT"
  exit 0
fi

nix flake lock --update-input nix-packages

updated_rev=$(python3 -c 'import json; print(json.load(open("flake.lock"))["nodes"]["nix-packages"]["locked"]["rev"])')
if [[ "$updated_rev" != "$latest_rev" ]]; then
  echo "Lock refresh selected ${updated_rev}, expected ${latest_rev}" >&2
  exit 1
fi

scripts/ci/verify-ai-package-stack.sh "$lock_file"

{
  echo "updated=true"
  echo "version=${latest_rev:0:12}"
  echo "revision=$latest_rev"
} >>"$GITHUB_OUTPUT"
