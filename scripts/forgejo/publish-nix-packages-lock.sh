#!/usr/bin/env bash
set -euo pipefail

: "${FORGEJO_TOKEN:?FORGEJO_TOKEN is required}"
: "${FORGEJO_URL:?FORGEJO_URL is required}"
: "${FORGEJO_OWNER:?FORGEJO_OWNER is required}"
: "${FORGEJO_REPO:?FORGEJO_REPO is required}"
: "${BASE_BRANCH:?BASE_BRANCH is required}"
: "${REVISION:?REVISION is required}"

if [[ "$BASE_BRANCH" != "dev" ]]; then
	echo "Refusing unexpected lock-update base branch" >&2
	exit 1
fi

git config user.name "forgejo-actions"
git config user.email "forgejo-actions@alc.xyz"
git remote set-url origin "${FORGEJO_URL}/${FORGEJO_OWNER}/${FORGEJO_REPO}.git"
auth_header=$(printf '%s:%s' "$FORGEJO_OWNER" "$FORGEJO_TOKEN" | base64 -w0)
git config --local "http.${FORGEJO_URL}/.extraheader" "AUTHORIZATION: basic ${auth_header}"

prepare_verified_lock() {
	local latest_head
	local updated_rev

	git fetch origin "$BASE_BRANCH"
	latest_head=$(git rev-parse "origin/${BASE_BRANCH}")

	# The previous workflow step leaves a verified lock change in the checkout.
	# Regenerate it from the latest base so unrelated commits made during that
	# build cannot be lost or force us to publish stale state.
	if ! git diff --quiet -- flake.lock; then
		git restore --source=HEAD --worktree -- flake.lock
	fi
	git switch --detach "$latest_head"
	nix flake lock --update-input nix-packages

	updated_rev=$(python3 -c 'import json; print(json.load(open("flake.lock"))["nodes"]["nix-packages"]["locked"]["rev"])')
	if [[ "$updated_rev" != "$REVISION" ]]; then
		echo "Latest-base lock selected ${updated_rev}, expected ${REVISION}" >&2
		exit 1
	fi

	if git diff --quiet -- flake.lock; then
		return 0
	fi

	scripts/ci/verify-ai-package-stack.sh flake.lock
}

for publish_attempt in 1 2 3; do
	prepare_verified_lock
	if git diff --quiet -- flake.lock; then
		echo "The latest ${BASE_BRANCH} already contains nix-packages ${REVISION:0:12}."
		exit 0
	fi

	git add flake.lock
	git commit -m "chore(nix-packages): update lock to ${REVISION:0:12}"
	if git push origin "HEAD:refs/heads/${BASE_BRANCH}"; then
		echo "Published verified nix-packages lock update to ${BASE_BRANCH}."
		exit 0
	fi

	if ((publish_attempt < 3)); then
		echo "${BASE_BRANCH} advanced during publication; regenerating and re-verifying (attempt $((publish_attempt + 1))/3)." >&2
	fi
done

echo "${BASE_BRANCH} kept advancing while the lock was published; deferring until the next run." >&2
exit 1
