#!/usr/bin/env bash
set -euo pipefail

: "${FORGEJO_TOKEN:?FORGEJO_TOKEN is required}"
: "${FORGEJO_URL:?FORGEJO_URL is required}"
: "${FORGEJO_OWNER:?FORGEJO_OWNER is required}"
: "${FORGEJO_REPO:?FORGEJO_REPO is required}"
: "${BASE_BRANCH:?BASE_BRANCH is required}"
: "${UPDATE_BRANCH:?UPDATE_BRANCH is required}"

if [[ "$BASE_BRANCH" != dev || "$UPDATE_BRANCH" != update/dms-plugins-lock ]]; then
  echo 'Refusing unexpected DMS lock branch configuration' >&2
  exit 1
fi

api_base="${FORGEJO_URL}/api/v1/repos/${FORGEJO_OWNER}/${FORGEJO_REPO}"
curl_config=$(mktemp)
payload=$(mktemp)
response=$(mktemp)
trap 'rm -f "$curl_config" "$payload" "$response"' EXIT
chmod 600 "$curl_config"
python3 -c 'import json, os; print("header = " + json.dumps("Authorization: token " + os.environ["FORGEJO_TOKEN"]))' >"$curl_config"

curl -fsS -K "$curl_config" -H 'Accept: application/json' \
  "${api_base}/pulls?state=open&base=${BASE_BRANCH}&limit=100" -o "$response"
mapfile -t candidates < <(jq -r --arg head "$UPDATE_BRANCH" --arg repo "${FORGEJO_OWNER}/${FORGEJO_REPO}" \
  '.[] | select(.head.ref == $head and .head.repo.full_name == $repo) | .number // .index' "$response")
if ((${#candidates[@]} == 0)); then
  echo 'No open DMS lock update PR.'
  exit 0
fi
if ((${#candidates[@]} != 1)); then
  echo 'Expected exactly one DMS lock update PR.' >&2
  exit 1
fi
pr_number=${candidates[0]}

curl -fsS -K "$curl_config" -H 'Accept: application/json' "${api_base}/pulls/${pr_number}" -o "$response"
head_sha=$(jq -r '.head.sha' "$response")
base_sha=$(jq -r '.base.sha' "$response")
merge_base=$(jq -r '.merge_base // ""' "$response")
mergeable=$(jq -r '.mergeable' "$response")
if [[ ! "$head_sha" =~ ^[0-9a-f]{40}$ || ! "$base_sha" =~ ^[0-9a-f]{40}$ ||
  "$(jq -r '.head.ref' "$response")" != "$UPDATE_BRANCH" ||
  "$(jq -r '.base.ref' "$response")" != "$BASE_BRANCH" ||
  "$(jq -r '.head.repo.full_name' "$response")" != "${FORGEJO_OWNER}/${FORGEJO_REPO}" ||
  "$mergeable" != true || "$merge_base" != "$base_sha" ]]; then
  echo "DMS lock update PR #${pr_number} is not a current clean candidate." >&2
  exit 1
fi

git fetch origin "refs/heads/${BASE_BRANCH}:refs/remotes/origin/${BASE_BRANCH}" \
  "refs/heads/${UPDATE_BRANCH}:refs/remotes/origin/${UPDATE_BRANCH}"
if [[ "$(git rev-parse "origin/${BASE_BRANCH}")" != "$base_sha" ||
"$(git rev-parse "origin/${UPDATE_BRANCH}")" != "$head_sha" ||
"$(git rev-parse "${head_sha}^")" != "$base_sha" ||
"$(git diff --name-only --no-renames "$base_sha" "$head_sha")" != flake.lock ]]; then
  echo "DMS lock update PR #${pr_number} changed outside its verified lock-only head." >&2
  exit 1
fi

curl -fsS -K "$curl_config" -H 'Accept: application/json' "${api_base}/commits/${head_sha}/status" -o "$response"
for context in 'ci/dms-lock-build' 'ci/dms-lock-validation'; do
  state=$(jq -r --arg context "$context" \
    '[(.statuses // [])[] | select(.context == $context)] | sort_by(.id) | last.status // "missing"' "$response")
  case "$state" in
    success) ;;
    missing | pending | warning)
      echo "DMS lock update PR #${pr_number} awaits ${context} (${state})."
      exit 0
      ;;
    *)
      echo "DMS lock update PR #${pr_number} has unsuccessful ${context} (${state})." >&2
      exit 1
      ;;
  esac
done

# The status was attached to an immutable commit; verify its branch and base
# still identify this PR just before requesting a guarded merge.
curl -fsS -K "$curl_config" -H 'Accept: application/json' "${api_base}/pulls/${pr_number}" -o "$response"
if [[ "$(jq -r '.head.sha' "$response")" != "$head_sha" ||
"$(jq -r '.base.sha' "$response")" != "$base_sha" ||
"$(jq -r '.merge_base // ""' "$response")" != "$base_sha" ||
"$(jq -r '.mergeable' "$response")" != true ]]; then
  echo "DMS lock update PR #${pr_number} moved while validation was checked." >&2
  exit 1
fi

jq -n --arg title "chore(dms): update verified plugin lock (#${pr_number})" --arg head "$head_sha" \
  '{Do: "squash", MergeTitleField: $title, MergeMessageField: "Verified lock update and exact-head validation.", head_commit_id: $head, delete_branch_after_merge: true}' \
  >"$payload"
status=$(curl -sS -K "$curl_config" -H 'Accept: application/json' -H 'Content-Type: application/json' \
  -o "$response" -w '%{http_code}' -X POST --data @"$payload" "${api_base}/pulls/${pr_number}/merge")
case "$status" in
  200 | 201 | 204) echo "Merged verified DMS lock update PR #${pr_number}." ;;
  *)
    echo "Failed to merge DMS lock update PR #${pr_number}; HTTP ${status}" >&2
    exit 1
    ;;
esac
