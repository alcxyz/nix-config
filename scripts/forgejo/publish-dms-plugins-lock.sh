#!/usr/bin/env bash
set -euo pipefail

if [[ -n ${FORGEJO_TOKEN_FILE:-} ]]; then
  if [[ ! -r $FORGEJO_TOKEN_FILE ]]; then
    echo "FORGEJO_TOKEN_FILE is not readable" >&2
    exit 2
  fi
elif [[ -z ${FORGEJO_TOKEN:-} ]]; then
  echo "FORGEJO_TOKEN_FILE or FORGEJO_TOKEN is required" >&2
  exit 2
fi
: "${FORGEJO_URL:?FORGEJO_URL is required}"
: "${FORGEJO_OWNER:?FORGEJO_OWNER is required}"
: "${FORGEJO_REPO:?FORGEJO_REPO is required}"
: "${BASE_BRANCH:?BASE_BRANCH is required}"
: "${UPDATE_BRANCH:?UPDATE_BRANCH is required}"
: "${REVISION:?REVISION is required}"
: "${VERSION:?VERSION is required}"

if [[ "$BASE_BRANCH" != "dev" || "$UPDATE_BRANCH" != "update/dms-plugins-lock" ]]; then
  echo "Refusing unexpected lock-update branch configuration" >&2
  exit 1
fi

if git diff --quiet -- flake.lock; then
  echo "No lock change to publish."
  exit 0
fi
if [[ "$(git status --porcelain --untracked-files=all)" != ' M flake.lock' ]]; then
  echo "Refusing to publish a tree with changes beyond flake.lock" >&2
  exit 1
fi

git fetch origin "$BASE_BRANCH"
base_sha=$(git rev-parse "origin/${BASE_BRANCH}")
if [[ "$(git rev-parse HEAD)" != "$base_sha" ]]; then
  echo "Refusing to publish from a stale ${BASE_BRANCH} checkout" >&2
  exit 1
fi

if [[ -z ${FORGEJO_TOKEN_FILE:-} ]]; then
  # Hosted compatibility: the local operator path uses its native Git helper.
  git remote set-url origin "${FORGEJO_URL}/${FORGEJO_OWNER}/${FORGEJO_REPO}.git"
  auth_header=$(printf '%s:%s' "$FORGEJO_OWNER" "$FORGEJO_TOKEN" | base64 -w0)
  export GIT_CONFIG_COUNT=2
  export GIT_CONFIG_KEY_0="http.${FORGEJO_URL}/.extraheader"
  export GIT_CONFIG_VALUE_0=
  export GIT_CONFIG_KEY_1="http.${FORGEJO_URL}/.extraheader"
  export GIT_CONFIG_VALUE_1="AUTHORIZATION: basic ${auth_header}"
fi

remote_ref=$(git ls-remote --heads origin "$UPDATE_BRANCH" | awk '{print $1}')
head_sha=
if [[ -n "$remote_ref" ]]; then
  git fetch origin "$UPDATE_BRANCH"
  if [[ "$(git rev-parse "${remote_ref}^")" == "$base_sha" &&
  "$(git diff --name-only "$base_sha" "$remote_ref")" == flake.lock &&
  "$(git rev-parse "${remote_ref}:flake.lock")" == "$(git hash-object flake.lock)" ]]; then
    head_sha=$remote_ref
    echo "Reusing unchanged DMS lock candidate ${head_sha:0:12}."
  fi
fi

if [[ -z "$head_sha" ]]; then
  if [[ -z $(git config user.name) || -z $(git config user.email) ]]; then
    echo "A configured Git author and committer identity is required." >&2
    exit 1
  fi
  git switch -C "$UPDATE_BRANCH"
  git add flake.lock
  git commit -m "chore(dms): update plugin lock to ${REVISION:0:12}" \
    -m "Refresh the verified aggregate plugin pin for the current development head."
  head_sha=$(git rev-parse HEAD)
  lease_args=()
  if [[ -n "$remote_ref" ]]; then
    lease_args=("--force-with-lease=refs/heads/${UPDATE_BRANCH}:${remote_ref}")
  fi
  git push "${lease_args[@]}" origin "HEAD:refs/heads/${UPDATE_BRANCH}"
fi

api_base="${FORGEJO_URL}/api/v1/repos/${FORGEJO_OWNER}/${FORGEJO_REPO}"
payload=$(mktemp)
response=$(mktemp)
curl_config=$(mktemp)
chmod 600 "$curl_config"
trap 'rm -f "$payload" "$response" "$curl_config"' EXIT
python3 - "${FORGEJO_TOKEN_FILE:-}" <<'PY' >"$curl_config"
import json
import os
import sys

token = open(sys.argv[1], encoding="utf-8").read().strip() if sys.argv[1] else os.environ["FORGEJO_TOKEN"]
print("header = " + json.dumps("Authorization: token " + token))
PY

jq -n \
  --arg base "$BASE_BRANCH" \
  --arg head "$UPDATE_BRANCH" \
  --arg title "chore(dms): update plugins to ${REVISION:0:12}" \
  --arg body "Automated, build-verified refresh of the aggregate DMS plugin lock to \`${REVISION}\` (DankAIUsage ${VERSION})." \
  '{base: $base, head: $head, title: $title, body: $body}' >"$payload"

status=$(curl -sS -K "$curl_config" -H "Accept: application/json" -H "Content-Type: application/json" -o "$response" -w '%{http_code}' \
  --data @"$payload" "${api_base}/pulls")

case "$status" in
  200 | 201)
    pr_number=$(jq -r '.number // .index' "$response")
    ;;
  409 | 422)
    curl -fsS -K "$curl_config" -H "Accept: application/json" -H "Content-Type: application/json" \
      "${api_base}/pulls?state=open&base=${BASE_BRANCH}&limit=100" -o "$response"
    pr_number=$(jq -r --arg head "$UPDATE_BRANCH" --arg repo "${FORGEJO_OWNER}/${FORGEJO_REPO}" \
      '.[] | select(.head.ref == $head and .head.repo.full_name == $repo) | .number // .index' "$response" | head -n1)
    ;;
  *)
    echo "Failed to create DMS plugins lock update PR; HTTP ${status}" >&2
    cat "$response" >&2
    exit 1
    ;;
esac

if [[ -z "$pr_number" || "$pr_number" == "null" ]]; then
  echo "Unable to identify the DMS plugins lock update PR" >&2
  exit 1
fi

curl -fsS -K "$curl_config" -H "Accept: application/json" "${api_base}/pulls/${pr_number}" -o "$response"
if ! jq -e --arg number "$pr_number" --arg base "$BASE_BRANCH" \
  --arg head "$UPDATE_BRANCH" --arg repo "${FORGEJO_OWNER}/${FORGEJO_REPO}" \
  '(.number // .index | tostring) == $number and .state == "open" and
   .base.ref == $base and .head.ref == $head and .head.repo.full_name == $repo' \
  "$response" >/dev/null; then
  echo "DMS plugins lock update PR #${pr_number} has unexpected identity; leaving it open." >&2
  exit 1
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
token_file=$(mktemp)
chmod 600 "$token_file"
if [[ -n ${FORGEJO_TOKEN_FILE:-} ]]; then
  cp "$FORGEJO_TOKEN_FILE" "$token_file"
else
  printf '%s' "$FORGEJO_TOKEN" >"$token_file"
fi
trap 'rm -f "$payload" "$response" "$curl_config" "$token_file"' EXIT
if ! python3 "${script_dir}/commit-status.py" require \
  --url "$FORGEJO_URL" --owner "$FORGEJO_OWNER" --repo "$FORGEJO_REPO" \
  --sha "$head_sha" --context ci/dms-lock-build >/dev/null 2>&1; then
  python3 "${script_dir}/commit-status.py" publish \
    --url "$FORGEJO_URL" --owner "$FORGEJO_OWNER" --repo "$FORGEJO_REPO" \
    --sha "$head_sha" --context ci/dms-lock-build --state success \
    --description "Verified DMS lock and Home Manager activation build" \
    --token-file "$token_file"
fi

if ! python3 "${script_dir}/commit-status.py" require \
  --url "$FORGEJO_URL" --owner "$FORGEJO_OWNER" --repo "$FORGEJO_REPO" \
  --sha "$head_sha" --context ci/dms-lock-validation >/dev/null 2>&1; then
  jq -n --arg ref "$head_sha" '{ref: $ref}' >"$payload"
  status=$(curl -sS -K "$curl_config" -H "Accept: application/json" -H "Content-Type: application/json" -o "$response" -w '%{http_code}' \
    --data @"$payload" "${api_base}/actions/workflows/validate-dms-lock.yml/dispatches")
  case "$status" in
    201 | 204) ;;
    *)
      echo "Failed to dispatch exact-head DMS validation; HTTP ${status}" >&2
      exit 1
      ;;
  esac
fi

echo "DMS plugins lock update PR #${pr_number} awaits exact-head validation and the merge queue."
