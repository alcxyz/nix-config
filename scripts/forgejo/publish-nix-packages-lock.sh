#!/usr/bin/env bash
set -euo pipefail

: "${FORGEJO_TOKEN:?FORGEJO_TOKEN is required}"
: "${FORGEJO_URL:?FORGEJO_URL is required}"
: "${FORGEJO_OWNER:?FORGEJO_OWNER is required}"
: "${FORGEJO_REPO:?FORGEJO_REPO is required}"
: "${BASE_BRANCH:?BASE_BRANCH is required}"
: "${UPDATE_BRANCH:?UPDATE_BRANCH is required}"
: "${REVISION:?REVISION is required}"

if [[ "$BASE_BRANCH" != "dev" || "$UPDATE_BRANCH" != "update/nix-packages-lock" ]]; then
	echo "Refusing unexpected lock-update branch configuration" >&2
	exit 1
fi

if git diff --quiet -- flake.lock; then
	echo "No lock change to publish."
	exit 0
fi

git fetch origin "$BASE_BRANCH"
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/${BASE_BRANCH}")" ]]; then
	echo "Refusing to publish from a stale ${BASE_BRANCH} checkout" >&2
	exit 1
fi

git config user.name "forgejo-actions"
git config user.email "forgejo-actions@alc.xyz"
git switch -C "$UPDATE_BRANCH"
git add flake.lock
git commit -m "chore(nix-packages): update lock to ${REVISION:0:12}"

git remote set-url origin "${FORGEJO_URL}/${FORGEJO_OWNER}/${FORGEJO_REPO}.git"
auth_header=$(printf '%s:%s' "$FORGEJO_OWNER" "$FORGEJO_TOKEN" | base64 -w0)
git config --local "http.${FORGEJO_URL}/.extraheader" "AUTHORIZATION: basic ${auth_header}"

lease_args=()
remote_ref=$(git ls-remote --heads origin "$UPDATE_BRANCH" | awk '{print $1}')
if [[ -n "$remote_ref" ]]; then
	lease_args=("--force-with-lease=refs/heads/${UPDATE_BRANCH}:${remote_ref}")
fi
git push "${lease_args[@]}" origin "HEAD:refs/heads/${UPDATE_BRANCH}"

api_base="${FORGEJO_URL}/api/v1/repos/${FORGEJO_OWNER}/${FORGEJO_REPO}"
api_auth=(-H "Authorization: token ${FORGEJO_TOKEN}" -H "Accept: application/json" -H "Content-Type: application/json")
payload=$(mktemp)
response=$(mktemp)
trap 'rm -f "$payload" "$response"' EXIT

jq -n \
	--arg base "$BASE_BRANCH" \
	--arg head "$UPDATE_BRANCH" \
	--arg title "chore(nix-packages): update lock to ${REVISION:0:12}" \
	--arg body "Automated, build-verified refresh of the nix-packages dev lock to \`${REVISION}\`." \
	'{base: $base, head: $head, title: $title, body: $body}' >"$payload"

status=$(curl -sS -o "$response" -w '%{http_code}' "${api_auth[@]}" \
	--data @"$payload" "${api_base}/pulls")

case "$status" in
200 | 201)
	pr_number=$(jq -r '.number // .index' "$response")
	;;
409 | 422)
	curl -fsS "${api_auth[@]}" \
		"${api_base}/pulls?state=open&base=${BASE_BRANCH}&limit=100" -o "$response"
	pr_number=$(jq -r --arg head "$UPDATE_BRANCH" '.[] | select(.head.ref == $head) | .number // .index' "$response" | head -n1)
	;;
*)
	echo "Failed to create lock update PR; HTTP ${status}" >&2
	cat "$response" >&2
	exit 1
	;;
esac

if [[ -z "$pr_number" || "$pr_number" == "null" ]]; then
	echo "Unable to identify the lock update PR" >&2
	exit 1
fi

curl -fsS "${api_auth[@]}" "${api_base}/pulls/${pr_number}" -o "$response"
mergeable=$(jq -r '.mergeable' "$response")
head_sha=$(jq -r '.head.sha' "$response")
base_sha=$(jq -r '.base.sha' "$response")
merge_base=$(jq -r '.merge_base // ""' "$response")

if [[ "$mergeable" != "true" || "$merge_base" != "$base_sha" ]]; then
	echo "Lock update PR #${pr_number} is not a clean fast-forward candidate; leaving it open." >&2
	exit 1
fi

jq -n \
	--arg title "chore(nix-packages): update lock to ${REVISION:0:12} (#${pr_number})" \
	--arg head "$head_sha" \
	'{Do: "squash", MergeTitleField: $title, MergeMessageField: "", head_commit_id: $head, delete_branch_after_merge: true}' \
	>"$payload"

status=$(curl -sS -o "$response" -w '%{http_code}' "${api_auth[@]}" \
	-X POST --data @"$payload" "${api_base}/pulls/${pr_number}/merge")
case "$status" in
200 | 201 | 204)
	echo "Merged verified nix-packages lock update PR #${pr_number}."
	;;
*)
	echo "Failed to merge lock update PR #${pr_number}; HTTP ${status}" >&2
	cat "$response" >&2
	exit 1
	;;
esac
