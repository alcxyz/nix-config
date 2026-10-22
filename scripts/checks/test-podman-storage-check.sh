#!/usr/bin/env bash
set -euo pipefail
source_file=${1:?storage check source required}
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/bin"
printf '#!%s\n' "$BASH" >"$fixture/bin/findmnt"
cat >>"$fixture/bin/findmnt" <<'EOF'
[[ $* == '-rn --mountpoint /fixture/podman -o SOURCE' ]] || exit 2
[[ ${FIXTURE_MOUNT:-present} == present ]] || exit 1
printf '%s\n' "${FIXTURE_SOURCE:-fixture/runtime/podman}"
EOF
chmod +x "$fixture/bin/findmnt"
export PATH="$fixture/bin:$PATH"
bash "$source_file" /fixture/podman fixture/runtime/podman
for mode in absent wrong ambiguous; do
  case $mode in
    absent) export FIXTURE_MOUNT=absent FIXTURE_SOURCE=fixture/runtime/podman ;;
    wrong) export FIXTURE_MOUNT=present FIXTURE_SOURCE=fixture/root ;;
    ambiguous) export FIXTURE_MOUNT=present FIXTURE_SOURCE=$'fixture/runtime/podman\nfixture/root' ;;
  esac
  if bash "$source_file" /fixture/podman fixture/runtime/podman >"$fixture/out" 2>&1; then
    echo "Storage check accepted $mode mount identity" >&2
    exit 1
  fi
done
echo 'Podman storage identity checks passed.'
