#!/usr/bin/env bash
set -euo pipefail

root=$1
repos_file=$2
shift 2
mode="sync"

case "${1:-}" in
  --status)
    mode="status"
    ;;
  --help | -h)
    cat <<'USAGE'
workspace-sync [--status]

Bootstraps the declared ~/src workspace.

Default behavior is conservative:
  - create missing parent directories
  - clone missing repositories
  - skip existing git repositories
  - warn and skip existing non-git paths
  - never pull, reset, clean, overwrite, or delete
USAGE
    exit 0
    ;;
  "")
    ;;
  *)
    printf 'workspace-sync: unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

mkdir -p "$root"
while IFS= read -r dir; do
  mkdir -p "$root/$dir"
done < <(jq -r '.directories[]' "$repos_file")

existing=0
cloned=0
missing=0
skipped=0
failed=0
failures=()

while IFS= read -r repo; do
  path="$(printf '%s\n' "$repo" | jq -r '.path')"
  url="$(printf '%s\n' "$repo" | jq -r '.url')"
  branch="$(printf '%s\n' "$repo" | jq -r '.branch // empty')"
  target="$root/$path"

  if [ -e "$target/.git" ] && git -C "$target" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'exists: %s\n' "$target"
    existing=$((existing + 1))
    continue
  fi

  if [ -e "$target" ]; then
    printf 'skip: %s exists but is not a git repository\n' "$target" >&2
    skipped=$((skipped + 1))
    continue
  fi

  if [ "$mode" = "status" ]; then
    printf 'missing: %s -> %s\n' "$target" "$url"
    missing=$((missing + 1))
    continue
  fi

  mkdir -p "$(dirname "$target")"
  if [ -n "$branch" ]; then
    if git clone --branch "$branch" "$url" "$target"; then
      cloned=$((cloned + 1))
    else
      printf 'failed: %s -> %s (branch: %s)\n' "$target" "$url" "$branch" >&2
      failures+=("$path -> $url (branch: $branch)")
      failed=$((failed + 1))
    fi
  else
    if git clone "$url" "$target"; then
      cloned=$((cloned + 1))
    else
      printf 'failed: %s -> %s\n' "$target" "$url" >&2
      failures+=("$path -> $url")
      failed=$((failed + 1))
    fi
  fi
done < <(jq -c '.repositories[]' "$repos_file")

if [ "$mode" = "status" ]; then
  printf '\nworkspace-sync status: %d existing, %d missing, %d skipped\n' "$existing" "$missing" "$skipped"
else
  printf '\nworkspace-sync summary: %d existing, %d cloned, %d skipped, %d failed\n' "$existing" "$cloned" "$skipped" "$failed"
  if [ "$failed" -gt 0 ]; then
    printf 'workspace-sync failed repositories:\n' >&2
    printf '  - %s\n' "${failures[@]}" >&2
    exit 1
  fi
fi
