#!/usr/bin/env bash
set -euo pipefail

for variable in CONFIG_REMOTE CONFIG_BRANCH NIX_PACKAGES_REMOTE_URL NIX_PACKAGES_BRANCH \
  NIX_PACKAGES_PROMOTED_BRANCH NIX_PACKAGES_QUEUE_API_URL FORGEJO_URL FORGEJO_OWNER FORGEJO_REPO \
  FORGEJO_STATUS_CONTEXT FORGEJO_API_TOKEN_FILE; do
  if [[ -z ${!variable:-} ]]; then
    echo "${variable} is required" >&2
    exit 2
  fi
done

for branch in "$CONFIG_BRANCH" "$NIX_PACKAGES_BRANCH" "$NIX_PACKAGES_PROMOTED_BRANCH"; do
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
cleanup() {
  local status=$?
  rm -rf -- "$work_root"
  # A deferred promotion must not hide a failing configuration head.
  if ((status == 75 && ${head_failed:-0})); then
    exit 1
  fi
}
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
# The promoted branch records the newest producer revision that passed the full
# configuration gate (ADR-0080). It is absent until the first promotion.
promoted_revision=$(git ls-remote "$NIX_PACKAGES_REMOTE_URL" "refs/heads/${NIX_PACKAGES_PROMOTED_BRANCH}" | awk 'NR == 1 {print $1}')

export NIX_PACKAGES_REMOTE_URL NIX_PACKAGES_BRANCH NIX_PACKAGES_QUEUE_API_URL
locked_revision=$(
  python3 - "$checkout/flake.lock" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    print(json.load(source)["nodes"]["nix-packages"]["locked"]["rev"])
PY
)

# Root validated check results outside the temporary checkout so scheduled GC
# does not force the next run to rebuild VM tests and patched packages.
validate_configurations() {
  local run_roots result
  if [[ -z ${CHECK_RESULTS_ROOT_DIR:-} ]]; then
    (cd "$checkout" && bash scripts/ci/check-configurations.sh)
    return
  fi
  mkdir -p -- "$CHECK_RESULTS_ROOT_DIR" || return
  # Drop partial roots left by runs that were killed before finishing.
  for stale in "$CHECK_RESULTS_ROOT_DIR"/run.*; do
    if [[ -d $stale && ! -e $stale/complete ]]; then
      rm -rf -- "$stale"
    fi
  done
  run_roots=$(mktemp -d "$CHECK_RESULTS_ROOT_DIR/run.XXXXXX") || return
  if (cd "$checkout" && CHECK_RESULTS_OUT_LINK="$run_roots/check" bash scripts/ci/check-configurations.sh); then
    touch -- "$run_roots/complete" || return
    # Keep only the latest successful run's roots.
    for stale in "$CHECK_RESULTS_ROOT_DIR"/run.*; do
      if [[ $stale != "$run_roots" ]]; then
        rm -rf -- "$stale"
      fi
    done
  else
    result=$?
    rm -rf -- "$run_roots"
    return "$result"
  fi
}

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
    return 0
  fi

  status "$base_revision" pending "Trusted local full validation is running"
  if validate_configurations; then
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

# Move the promoted branch to the validated producer revision. The update
# queue and producer head are rechecked directly before the push, and the lease
# rejects a concurrent promotion. No configuration commit is created.
publish_promotion() {
  local packages="$work_root/nix-packages"
  git init --quiet "$packages"
  git -C "$packages" remote add origin "$NIX_PACKAGES_REMOTE_URL"
  # Tracking refs let pre-push guards see that no new commits are published.
  git -C "$packages" fetch --quiet --no-tags --depth=1 origin \
    "+refs/heads/${NIX_PACKAGES_BRANCH}:refs/remotes/origin/${NIX_PACKAGES_BRANCH}"
  if [[ -n $promoted_revision ]]; then
    git -C "$packages" fetch --quiet --no-tags --depth=1 origin \
      "+refs/heads/${NIX_PACKAGES_PROMOTED_BRANCH}:refs/remotes/origin/${NIX_PACKAGES_PROMOTED_BRANCH}"
  fi
  if [[ $(git -C "$packages" rev-parse "refs/remotes/origin/${NIX_PACKAGES_BRANCH}") != "$producer_revision" ]]; then
    echo "Package promotion deferred because the producer branch advanced." >&2
    exit 75
  fi
  "$checkout/scripts/ci/check-package-promotion-readiness.sh" "$producer_revision"
  git -C "$packages" push --quiet \
    --force-with-lease="refs/heads/${NIX_PACKAGES_PROMOTED_BRANCH}:${promoted_revision}" \
    origin "${producer_revision}:refs/heads/${NIX_PACKAGES_PROMOTED_BRANCH}"
  if [[ $(git ls-remote "$NIX_PACKAGES_REMOTE_URL" "refs/heads/${NIX_PACKAGES_PROMOTED_BRANCH}" | awk 'NR == 1 {print $1}') != "$producer_revision" ]]; then
    echo "Published package promotion could not be confirmed." >&2
    exit 1
  fi
  echo "Promoted locally verified package revision ${producer_revision:0:12}."
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

if [[ $promoted_revision == "$producer_revision" ]]; then
  validate_current_head
  exit 0
fi

if [[ $locked_revision == "$producer_revision" ]]; then
  # The committed lock already selects the producer, so the configuration
  # head's own receipt covers the configuration gate.
  validate_current_head
  # Validation can take hours; defer rather than verify a superseded producer.
  "$checkout/scripts/ci/check-package-promotion-readiness.sh" "$producer_revision"
  (
    cd "$checkout"
    scripts/ci/verify-ai-package-stack.sh flake.lock
  )
  publish_promotion
  exit 0
fi

# The configuration head is not superseded by a lock commit, so it needs its
# own receipt for main promotion. A failing head still lets a producer that
# fixes it be validated and promoted.
head_failed=0
if ! validate_current_head; then
  head_failed=1
  echo "The configuration head has no success receipt; validating the package candidate anyway." >&2
fi
# Head validation can take hours; defer rather than lock a newer producer.
"$checkout/scripts/ci/check-package-promotion-readiness.sh" "$producer_revision"

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
)
validate_configurations

if [[ $(git -C "$checkout" status --porcelain) != " M flake.lock" ]]; then
  echo "Validation changed files other than the package lock; refusing publication." >&2
  exit 1
fi
publish_promotion
if ((head_failed)); then
  echo "The package candidate was promoted, but the configuration head has no success receipt." >&2
  exit 1
fi
