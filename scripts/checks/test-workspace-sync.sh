#!/usr/bin/env bash
# Manifest expressions use jq variables, not shell interpolation.
# shellcheck disable=SC2016
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo_root/modules/home-manager/workspace/workspace-sync.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

git init -q -b main "$fixture/source"
printf 'original\n' >"$fixture/source/tracked"
git -C "$fixture/source" add tracked
git -C "$fixture/source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm initial

manifest="$fixture/manifest.json"
root="$fixture/workspace"
make_manifest() {
  jq -n --arg source "$fixture/source" --arg missing "$fixture/nonexistent" \
    "{directories: [\"apps\", \"scratch\"], repositories: $1}" >"$manifest"
}
sync_workspace() { bash "$script" "$root" "$manifest" "$@" >"$fixture/output" 2>&1; }

# Successful clones and existing repositories have a successful exit status.
make_manifest '[{path:"apps/success",url:$source,branch:"main"}]'
sync_workspace
grep -q '0 existing, 1 cloned, 0 skipped, 0 failed' "$fixture/output"
cmp "$fixture/source/tracked" "$root/apps/success/tracked"
printf 'local edit\n' >"$root/apps/success/tracked"
sync_workspace
grep -q '1 existing, 0 cloned, 0 skipped, 0 failed' "$fixture/output"
[ "$(cat "$root/apps/success/tracked")" = 'local edit' ] || fail 'existing checkout was modified'

# Failed clones are summarized and return failure.
make_manifest '[{path:"apps/failure",url:$missing}]'
if sync_workspace; then fail 'failed clone returned success'; fi
grep -q '0 existing, 0 cloned, 0 skipped, 1 failed' "$fixture/output"
grep -q 'workspace-sync failed repositories:' "$fixture/output"

# A failed named branch must not stop later successful clones.
make_manifest '[{path:"apps/bad-branch",url:$source,branch:"nonexistent"},{path:"apps/later",url:$source}]'
if sync_workspace; then fail 'mixed clones returned success'; fi
grep -q '0 existing, 1 cloned, 0 skipped, 1 failed' "$fixture/output"
cmp "$fixture/source/tracked" "$root/apps/later/tracked"

# Worktrees count as existing, while non-Git paths (including directories
# inside another repository) remain untouched and are counted as skipped.
git -C "$fixture/source" worktree add -q --detach "$root/apps/worktree"
printf 'worktree edit\n' >"$root/apps/worktree/tracked"
mkdir -p "$root/apps/success/ordinary"
printf 'keep\n' >"$root/apps/success/ordinary/file"
printf 'keep file\n' >"$root/apps/file"
make_manifest '[{path:"apps/worktree",url:$missing},{path:"apps/success/ordinary",url:$missing},{path:"apps/file",url:$missing}]'
sync_workspace
grep -q '1 existing, 0 cloned, 2 skipped, 0 failed' "$fixture/output"
[ "$(cat "$root/apps/worktree/tracked")" = 'worktree edit' ] || fail 'worktree was modified'
[ "$(cat "$root/apps/success/ordinary/file")" = keep ] || fail 'non-Git directory was modified'
[ "$(cat "$root/apps/file")" = 'keep file' ] || fail 'existing file was modified'

# Status reports missing entries without attempting clones or reporting failure.
make_manifest '[{path:"apps/worktree",url:$missing},{path:"apps/not-cloned",url:$source}]'
sync_workspace --status
grep -q '1 existing, 1 missing, 0 skipped' "$fixture/output"
[ ! -e "$root/apps/not-cloned" ] || fail 'status cloned a repository'

echo 'Workspace sync tests passed'
