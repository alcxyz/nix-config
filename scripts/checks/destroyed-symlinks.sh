#!/usr/bin/env bash
set -euo pipefail

failed=0

while IFS= read -r path; do
  [ -e "$path" ] || continue
  if [ -L "$path" ]; then
    continue
  fi

  target=$(git cat-file -p "HEAD:$path" 2>/dev/null || true)
  if [ -n "$target" ] && [ "$(cat "$path" 2>/dev/null || true)" = "$target" ]; then
    printf 'Destroyed symlink: %s now contains its previous target path\n' "$path" >&2
    failed=1
  fi
done < <(git ls-files -s | awk '$1 == "120000" { print $4 }')

exit "$failed"
