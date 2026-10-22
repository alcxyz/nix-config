set -euo pipefail

target=${1:?mountpoint required}
expected=${2:?expected source required}
actual=$(findmnt -rn --mountpoint "$target" -o SOURCE) || {
  echo 'Dedicated CI Podman filesystem is not mounted.' >&2
  exit 1
}
# Block-device aliases may differ from findmnt's canonical device spelling.
if [[ -b $expected && -b $actual ]]; then
  expected=$(readlink -f -- "$expected")
  actual=$(readlink -f -- "$actual")
fi
if [[ $actual != "$expected" ]]; then
  echo 'Dedicated CI Podman filesystem has an unexpected source.' >&2
  exit 1
fi
