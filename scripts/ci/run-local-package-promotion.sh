#!/usr/bin/env bash
set -euo pipefail

for variable in CONFIG_REMOTE CONFIG_BRANCH NIX_PACKAGES_REMOTE_URL NIX_PACKAGES_BRANCH \
  NIX_PACKAGES_QUEUE_API_URL FORGEJO_URL FORGEJO_OWNER FORGEJO_REPO \
  FORGEJO_STATUS_CONTEXT FORGEJO_API_TOKEN_FILE; do
  if [[ -z ${!variable:-} ]]; then
    echo "${variable} is required" >&2
    exit 2
  fi
done

for branch in "$CONFIG_BRANCH" "$NIX_PACKAGES_BRANCH"; do
  if [[ ! $branch =~ ^[A-Za-z0-9._/-]+$ || $branch == *..* ]]; then
    echo "Invalid branch name" >&2
    exit 2
  fi
done

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
cleanup() { rm -rf -- "$work_root"; }
trap cleanup EXIT

exec 9>"${XDG_RUNTIME_DIR:-$work_root}/nix-package-promotion.lock"
if ! flock -n 9; then
  echo "Another local package promotion is already running."
  exit 0
fi

checkout="$work_root/nix-config"
git init --quiet "$checkout"
git -C "$checkout" remote add origin "$CONFIG_REMOTE"
git -C "$checkout" fetch --quiet --no-tags origin "refs/heads/${CONFIG_BRANCH}"
base_revision=$(git -C "$checkout" rev-parse FETCH_HEAD)
git -C "$checkout" switch --quiet --detach "$base_revision"

remote_config_revision=$(git ls-remote "$CONFIG_REMOTE" "refs/heads/${CONFIG_BRANCH}" | awk 'NR == 1 {print $1}')
if [[ $remote_config_revision != "$base_revision" ]]; then
  echo "Configuration branch advanced during checkout; deferring." >&2
  exit 75
fi

producer_revision=$(git ls-remote "$NIX_PACKAGES_REMOTE_URL" "refs/heads/${NIX_PACKAGES_BRANCH}" | awk 'NR == 1 {print $1}')
if [[ ! $producer_revision =~ ^[0-9a-f]{40}$ ]]; then
  echo "Unable to resolve the package producer branch." >&2
  exit 1
fi

export NIX_PACKAGES_REMOTE_URL NIX_PACKAGES_BRANCH NIX_PACKAGES_QUEUE_API_URL
locked_revision=$(
  python3 - "$checkout/flake.lock" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    print(json.load(source)["nodes"]["nix-packages"]["locked"]["rev"])
PY
)

status() {
  local revision=$1 state=$2 description=$3
  python3 "$checkout/scripts/forgejo/commit-status.py" publish \
    --url "$FORGEJO_URL" --owner "$FORGEJO_OWNER" --repo "$FORGEJO_REPO" \
    --sha "$revision" --context "$FORGEJO_STATUS_CONTEXT" \
    --token-file "$FORGEJO_API_TOKEN_FILE" --state "$state" --description "$description"
}

validate_current_head() {
  if python3 "$checkout/scripts/forgejo/commit-status.py" require \
    --url "$FORGEJO_URL" --owner "$FORGEJO_OWNER" --repo "$FORGEJO_REPO" \
    --sha "$base_revision" --context "$FORGEJO_STATUS_CONTEXT"; then
    echo "The trusted configuration head already has an exact local validation receipt."
    exit 0
  fi

  status "$base_revision" pending "Trusted local full validation is running"
  if (cd "$checkout" && scripts/ci/check-configurations.sh); then
    if [[ $(git -C "$checkout" rev-parse HEAD) != "$base_revision" ]] ||
      [[ -n $(git -C "$checkout" status --porcelain) ]]; then
      echo "Configuration validation changed the exact candidate tree." >&2
      result=1
      status "$base_revision" failure "Trusted local full validation failed" || true
      return "$result"
    fi
    status "$base_revision" success "Trusted local full validation passed"
  else
    result=$?
    status "$base_revision" failure "Trusted local full validation failed" || true
    return "$result"
  fi
}

if "$checkout/scripts/ci/check-package-promotion-readiness.sh" "$producer_revision"; then
  :
else
  readiness_result=$?
  if ((readiness_result == 75)); then
    validate_current_head
  fi
  exit "$readiness_result"
fi

if [[ $locked_revision == "$producer_revision" ]]; then
  validate_current_head
  exit 0
fi

(
  cd "$checkout"
  nix flake lock --update-input nix-packages
)
updated_revision=$(
  python3 - "$checkout/flake.lock" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    print(json.load(source)["nodes"]["nix-packages"]["locked"]["rev"])
PY
)
if [[ $updated_revision != "$producer_revision" ]]; then
  echo "The refreshed lock did not select the observed producer revision." >&2
  exit 1
fi

(
  cd "$checkout"
  scripts/ci/verify-ai-package-stack.sh flake.lock
  scripts/ci/check-configurations.sh
)

if [[ $(git -C "$checkout" status --porcelain) != " M flake.lock" ]]; then
  echo "Validation changed files other than the package lock; refusing publication." >&2
  exit 1
fi
git -C "$checkout" add flake.lock
verified_tree=$(git -C "$checkout" write-tree)

# Recheck all moving publication inputs after the expensive build and directly
# before creating and pushing the commit. Any advance is deferred to a fresh run.
"$checkout/scripts/ci/check-package-promotion-readiness.sh" "$producer_revision"
remote_config_revision=$(git ls-remote "$CONFIG_REMOTE" "refs/heads/${CONFIG_BRANCH}" | awk 'NR == 1 {print $1}')
if [[ $remote_config_revision != "$base_revision" ]]; then
  echo "Configuration branch advanced during validation; deferring." >&2
  exit 75
fi

git -C "$checkout" -c user.name="local-package-promotion" \
  -c user.email="local-package-promotion@localhost" \
  commit --quiet -m "chore(nix-packages): update lock to ${producer_revision:0:12}"
published_revision=$(git -C "$checkout" rev-parse HEAD)
if [[ $(git -C "$checkout" rev-parse 'HEAD^{tree}') != "$verified_tree" ]]; then
  echo "Committed tree differs from the verified candidate." >&2
  exit 1
fi

git -C "$checkout" push --quiet origin "HEAD:refs/heads/${CONFIG_BRANCH}"
remote_config_revision=$(git ls-remote "$CONFIG_REMOTE" "refs/heads/${CONFIG_BRANCH}" | awk 'NR == 1 {print $1}')
if [[ $remote_config_revision != "$published_revision" ]]; then
  echo "Published configuration head could not be confirmed." >&2
  exit 1
fi
status "$published_revision" success "Trusted local package and configuration validation passed"
echo "Published a locally verified package lock."
