#!/usr/bin/env bash
# Move the nix-packages lock to the revision local package promotion validated
# (ADR-0080). Only flake.lock changes; review and commit it as usual.
#
# With --check, report when the lock differs from it instead. The deploy wrapper
# uses that form, so it never fails or changes the checkout.
set -euo pipefail

promoted_branch=promoted

check=false
if [[ ${1:-} == --check ]]; then
  check=true
fi

note() { echo "$*" >&2; }

entry=$(jq -ce '.nodes["nix-packages"] | select(.locked.type == "git" and .original.type == "git")' flake.lock 2>/dev/null) || {
  $check && exit 0
  note "flake.lock has no git nix-packages input"
  exit 1
}
url=$(jq -r '.original.url' <<<"$entry")
ref=$(jq -r '.original.ref // "HEAD"' <<<"$entry")
locked_revision=$(jq -r '.locked.rev' <<<"$entry")
locked_count=$(jq -r '.locked.revCount // empty' <<<"$entry")
# The lock may come from any checkout; never let it pass options to git.
if [[ ! $url =~ ^(https|ssh|file):// ]]; then
  $check && exit 0
  note "flake.lock locks nix-packages from an unsupported URL"
  exit 1
fi

promoted_revision=$(timeout 5 git ls-remote "$url" "refs/heads/${promoted_branch}" 2>/dev/null | awk 'NR == 1 {print $1}') || true
if [[ ! $promoted_revision =~ ^[0-9a-f]{40}$ ]]; then
  $check && exit 0
  note "could not resolve the promoted nix-packages revision"
  exit 1
fi

if [[ $promoted_revision == "$locked_revision" ]]; then
  $check || note "nix-packages is already locked to promoted ${promoted_revision:0:12}"
  exit 0
fi

if $check; then
  note "deploy: nix-packages is locked to ${locked_revision:0:12}, promoted is ${promoted_revision:0:12}; 'just lock-packages' updates an older lock"
  exit 0
fi

if [[ ! $locked_count =~ ^[0-9]+$ ]]; then
  note "flake.lock does not record how old the locked nix-packages is; leaving it"
  exit 1
fi
promoted_url="git+${url}?ref=${ref}&rev=${promoted_revision}"
promoted_count=$(nix flake metadata --json "$promoted_url" | jq -er '.locked.revCount')
if ((promoted_count <= locked_count)); then
  note "the locked nix-packages ${locked_revision:0:12} is not older than promoted ${promoted_revision:0:12}; leaving it"
  exit 0
fi

original=$(jq -c '.nodes["nix-packages"].original' flake.lock)
nix flake lock --override-input nix-packages "$promoted_url"
# A changed original would make the next evaluation relock from the moving ref.
if [[ $(jq -r '.nodes["nix-packages"].locked.rev' flake.lock) != "$promoted_revision" ]] ||
  [[ $(jq -c '.nodes["nix-packages"].original' flake.lock) != "$original" ]]; then
  note "the refreshed lock does not match promoted ${promoted_revision:0:12}; restore flake.lock before committing"
  exit 1
fi
note "locked nix-packages to promoted ${promoted_revision:0:12}; commit flake.lock to deploy it"
