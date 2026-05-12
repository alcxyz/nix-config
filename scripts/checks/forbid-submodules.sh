#!/usr/bin/env bash
set -euo pipefail

if [ -f .gitmodules ]; then
  echo "Submodules are not allowed in this repository." >&2
  exit 1
fi

if git ls-files --stage | awk '$1 == "160000" { print $4 }' | grep -q .; then
  echo "Submodule gitlinks are not allowed in this repository:" >&2
  git ls-files --stage | awk '$1 == "160000" { print "  " $4 }' >&2
  exit 1
fi
