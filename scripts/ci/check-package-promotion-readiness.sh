#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)) || [[ ! $1 =~ ^[0-9a-f]{40}$ ]]; then
  echo "Usage: $0 EXPECTED_NIX_PACKAGES_REVISION" >&2
  exit 2
fi

expected_revision=$1
remote_url=${NIX_PACKAGES_REMOTE_URL:-https://git.alc.xyz/alcxyz/nix-packages.git}
queue_api_url=${NIX_PACKAGES_QUEUE_API_URL:-https://git.alc.xyz/api/v1/repos/alcxyz/nix-packages/pulls?state=open\&base=dev\&limit=100}
branch=${NIX_PACKAGES_BRANCH:-dev}

for page in $(seq 1 100); do
  separator='&'
  [[ $queue_api_url == *'?'* ]] || separator='?'
  queue_json=$(curl -fsSL "${queue_api_url}${separator}page=${page}")
  if ! jq -e 'type == "array" and all(.[]; (.head.ref | type) == "string")' >/dev/null <<<"$queue_json"; then
    echo "Package update queue response is invalid." >&2
    exit 1
  fi
  if jq -e '.[] | select(.head.ref | startswith("update/"))' >/dev/null <<<"$queue_json"; then
    echo "Package promotion deferred while an update remains open." >&2
    exit 75
  fi
  queue_count=$(jq 'length' <<<"$queue_json")
  ((queue_count == 0)) && break
  if ((page == 100)); then
    echo "Package update queue exceeded the bounded pagination check." >&2
    exit 1
  fi
done

actual_revision=$(git ls-remote "$remote_url" "refs/heads/${branch}" | awk 'NR == 1 {print $1}')
if [[ $actual_revision != "$expected_revision" ]]; then
  echo "Package promotion deferred because the producer branch advanced." >&2
  exit 75
fi

echo "Package promotion readiness confirmed."
