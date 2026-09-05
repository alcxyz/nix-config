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

reconcile_latest_base() {
	local attempt
	local base_head
	local latest_head
	local updated_rev

	for attempt in 1 2 3; do
		base_head=$(git rev-parse HEAD)
		git fetch origin "$BASE_BRANCH"
		latest_head=$(git rev-parse "origin/${BASE_BRANCH}")

		if [[ "$base_head" == "$latest_head" ]]; then
			return 0
		fi

		echo "${BASE_BRANCH} advanced during verification; regenerating the lock on ${latest_head:0:12} (attempt ${attempt}/3)."
		git restore --source=HEAD --worktree -- flake.lock
		git switch --detach "$latest_head"
		nix flake lock --update-input nix-packages

		updated_rev=$(python3 -c 'import json; print(json.load(open("flake.lock"))["nodes"]["nix-packages"]["locked"]["rev"])')
		if [[ "$updated_rev" != "$REVISION" ]]; then
			echo "Rebased lock selected ${updated_rev}, expected ${REVISION}" >&2
			exit 1
		fi

		scripts/ci/verify-ai-package-stack.sh flake.lock
	done

	git fetch origin "$BASE_BRANCH"
	if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/${BASE_BRANCH}")" ]]; then
		echo "${BASE_BRANCH} kept advancing while the lock was re-verified; deferring publication." >&2
		exit 1
	fi
}

reconcile_latest_base

if git diff --quiet -- flake.lock; then
	echo "The latest ${BASE_BRANCH} already contains nix-packages ${REVISION:0:12}."
	exit 0
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
409)
	message=$(jq -r '.message // ""' "$response")
	if [[ "$message" != "PushRejected with remote message: Forgejo: User permission denied for writing." ]]; then
		echo "Failed to merge lock update PR #${pr_number}; HTTP ${status}" >&2
		cat "$response" >&2
		exit 1
	fi

	# Forgejo 10 can create the same-repository PR with its automatic Actions
	# token but rejects the server-side merge as the virtual Actions user. The
	# token can still push repository branches. HEAD is exactly one generated
	# commit ahead of the re-verified base, so a normal (non-forced) push keeps
	# the same fast-forward safety and fails closed if dev moved again.
	echo "Forgejo rejected the virtual-user merge; publishing the verified fast-forward directly."
	git push origin "HEAD:refs/heads/${BASE_BRANCH}"

	# A direct push normally marks the PR merged. If this Forgejo version leaves
	# it open, close the now-redundant PR before removing the update branch.
	curl -fsS "${api_auth[@]}" "${api_base}/pulls/${pr_number}" -o "$response"
	if [[ "$(jq -r '.state' "$response")" == "open" ]]; then
		jq -n '{state: "closed"}' >"$payload"
		curl -fsS "${api_auth[@]}" -X PATCH --data @"$payload" \
			"${api_base}/pulls/${pr_number}" -o "$response"
	fi
	git push origin --delete "$UPDATE_BRANCH" || true
	echo "Published verified nix-packages lock update from PR #${pr_number}."
	;;
*)
	echo "Failed to merge lock update PR #${pr_number}; HTTP ${status}" >&2
	cat "$response" >&2
	exit 1
	;;
esac
