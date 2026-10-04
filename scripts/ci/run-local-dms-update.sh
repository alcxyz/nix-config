#!/usr/bin/env bash
set -euo pipefail

for variable in CONFIG_REMOTE CONFIG_BRANCH FORGEJO_URL FORGEJO_OWNER FORGEJO_REPO \
  FORGEJO_API_TOKEN_FILE; do
  if [[ -z ${!variable:-} ]]; then
    echo "${variable} is required" >&2
    exit 2
  fi
done
if [[ $CONFIG_BRANCH != dev ]]; then
  echo "Only the committed dev branch is eligible for DMS updates." >&2
  exit 2
fi

python3 - "$CONFIG_REMOTE" "$FORGEJO_URL" "$FORGEJO_OWNER" "$FORGEJO_REPO" <<'PY'
import re
import sys
from urllib.parse import urlsplit

remote = urlsplit(sys.argv[1])
forgejo = urlsplit(sys.argv[2])
owner, repo = sys.argv[3:]
valid_name = re.compile(r"[A-Za-z0-9_.-]+")
if not all(valid_name.fullmatch(value) for value in (owner, repo)):
    raise SystemExit("Invalid receipt repository identity")
network_match = (
    remote.scheme in {"http", "https"}
    and remote.username is None
    and remote.scheme == forgejo.scheme
    and remote.netloc == forgejo.netloc
    and remote.path == f"{forgejo.path.rstrip('/')}/{owner}/{repo}.git"
)
local_match = (
    remote.scheme == forgejo.scheme == "file"
    and remote.path == f"{forgejo.path.rstrip('/')}/{owner}/{repo}.git"
)
if not (network_match or local_match):
    raise SystemExit("Configuration remote does not match the receipt repository")
PY

work_root=$(mktemp -d)
trap 'rm -rf -- "$work_root"' EXIT

# Serialize native builds with the local package promoter on the same host.
exec 9>"${XDG_RUNTIME_DIR:-$work_root}/nix-package-promotion.lock"
if ! flock -n 9; then
  echo "Another local promotion build is already running."
  exit 0
fi

checkout="$work_root/nix-config"
git init --quiet "$checkout"
git -C "$checkout" remote add origin "$CONFIG_REMOTE"
git -C "$checkout" fetch --quiet --no-tags origin refs/heads/dev
base_revision=$(git -C "$checkout" rev-parse FETCH_HEAD)
git -C "$checkout" switch --quiet --detach "$base_revision"

remote_revision=$(git ls-remote "$CONFIG_REMOTE" refs/heads/dev | awk 'NR == 1 {print $1}')
if [[ $remote_revision != "$base_revision" ]]; then
  echo "Configuration dev advanced during checkout; deferring." >&2
  exit 75
fi

export GITHUB_OUTPUT="$work_root/update-output"
(cd "$checkout" && bash scripts/update-inputs/update-dms-plugins.sh)
if [[ $(sed -n 's/^updated=//p' "$GITHUB_OUTPUT") != true ]]; then
  exit 0
fi

if [[ $(git -C "$checkout" status --porcelain --untracked-files=all) != ' M flake.lock' ]]; then
  echo "DMS validation changed files beyond flake.lock; refusing publication." >&2
  exit 1
fi
verified_blob=$(git -C "$checkout" hash-object flake.lock)
remote_revision=$(git ls-remote "$CONFIG_REMOTE" refs/heads/dev | awk 'NR == 1 {print $1}')
if [[ $remote_revision != "$base_revision" ]]; then
  echo "Configuration dev advanced during validation; deferring." >&2
  exit 75
fi
if [[ $(git -C "$checkout" hash-object flake.lock) != "$verified_blob" ]]; then
  echo "Validated DMS lock changed before publication." >&2
  exit 1
fi

export FORGEJO_TOKEN_FILE="$FORGEJO_API_TOKEN_FILE"
export FORGEJO_URL FORGEJO_OWNER FORGEJO_REPO
export BASE_BRANCH=dev UPDATE_BRANCH=update/dms-plugins-lock
export REVISION VERSION
REVISION=$(sed -n 's/^revision=//p' "$GITHUB_OUTPUT")
VERSION=$(sed -n 's/^version=//p' "$GITHUB_OUTPUT")
if [[ ! $REVISION =~ ^[0-9a-f]{40}$ || -z $VERSION ]]; then
  echo "DMS updater did not provide a valid verified revision and version." >&2
  exit 1
fi
(cd "$checkout" && bash scripts/forgejo/publish-dms-plugins-lock.sh)
