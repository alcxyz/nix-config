set -euo pipefail

target=${1:?mountpoint required}
expected=${2:?expected source required}
actual=$(findmnt -rn --mountpoint "$target" -o SOURCE) || {
  echo 'Dedicated CI runtime filesystem is not mounted.' >&2
  exit 1
}
# findmnt reports a bind mount as <device>[<path>]. Block-device aliases may
# differ from its canonical device spelling, so compare devices by identity.
expected_path=
actual_path=
if [[ $expected == *\[*\] ]]; then
  expected_path=[${expected#*\[}
  expected=${expected%%\[*}
fi
if [[ $actual == *\[*\] ]]; then
  actual_path=[${actual#*\[}
  actual=${actual%%\[*}
fi
if [[ -b $expected && -b $actual ]]; then
  expected=$(readlink -f -- "$expected")
  actual=$(readlink -f -- "$actual")
fi
expected+=$expected_path
actual+=$actual_path
if [[ $actual != "$expected" ]]; then
  echo 'Dedicated CI runtime filesystem has an unexpected source.' >&2
  exit 1
fi
