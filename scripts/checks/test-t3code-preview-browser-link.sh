#!/usr/bin/env bash
# Contract test for modules/home-manager/services/t3code/link-preview-browser.sh.
set -euo pipefail

script="$(cd "$(dirname "$0")/../.." && pwd)/modules/home-manager/services/t3code/link-preview-browser.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Two package bundles behind one profile link, like the ai-stack profile.
for version in 1.0.0.1 2.0.0.2; do
  mkdir -p "$work/bundle-$version/linux64/$version"
  touch "$work/bundle-$version/linux64/$version/chrome-headless-shell"
done
ln -s "$work/bundle-1.0.0.1" "$work/profile"
bundle="$work/profile"
base="$work/base"
root="$base/tools/chrome-headless-shell/linux64"

# A missing bundle is not an error and touches nothing.
bash "$script" "$work/missing" "$base" 2>/dev/null || fail "missing bundle exited nonzero"
[[ ! -e "$base" ]] || fail "missing bundle created the base directory"

# T3's own download of the same version is replaced by a link.
mkdir -p "$root/1.0.0.1"
touch "$root/1.0.0.1/chrome-headless-shell"
bash "$script" "$bundle/" "$base" >/dev/null
[[ -L "$root/1.0.0.1" ]] || fail "download was not replaced by a link"
[[ "$(readlink "$root/1.0.0.1")" == "$bundle/linux64/1.0.0.1" ]] ||
  fail "link does not keep the profile path: $(readlink "$root/1.0.0.1")"

# A second run with nothing to do is quiet and leaves the link alone.
output=$(bash "$script" "$bundle" "$base")
[[ -z "$output" ]] || fail "idempotent run printed: $output"

# After a profile switch the new version is linked and the stale link removed.
ln -sfn "$work/bundle-2.0.0.2" "$work/profile"
bash "$script" "$bundle" "$base" >/dev/null
[[ -L "$root/2.0.0.2" && -f "$root/2.0.0.2/chrome-headless-shell" ]] ||
  fail "new version was not linked"
[[ ! -L "$root/1.0.0.1" ]] || fail "stale link was kept"

# Real directories for other versions belong to T3 and stay.
mkdir -p "$root/3.0.0.3"
bash "$script" "$bundle" "$base" >/dev/null
[[ -d "$root/3.0.0.3" && ! -L "$root/3.0.0.3" ]] || fail "unrelated directory was removed"

# Usage errors exit 64.
status=0
bash "$script" "$bundle" >/dev/null 2>&1 || status=$?
[[ "$status" == 64 ]] || fail "usage error exited $status"

echo "t3code preview browser link: ok"
