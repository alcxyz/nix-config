#!/usr/bin/env bash
set -euo pipefail
source_file=${1:?storage check source required}
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/bin"
printf '#!%s\n' "$BASH" >"$fixture/bin/findmnt"
cat >>"$fixture/bin/findmnt" <<'EOF'
[[ $* == '-rn --mountpoint /var/lib/forgejo-docker -o SOURCE' ]] || exit 2
[[ ${FIXTURE_MOUNT:-present} == present ]] || exit 1
printf '%s\n' "${FIXTURE_SOURCE:-fixture/runtime/docker}"
EOF
chmod +x "$fixture/bin/findmnt"
export PATH="$fixture/bin:$PATH"
bash "$source_file" /var/lib/forgejo-docker fixture/runtime/docker
for mode in absent wrong ambiguous; do
  case $mode in
    absent) export FIXTURE_MOUNT=absent FIXTURE_SOURCE=fixture/runtime/docker ;;
    wrong) export FIXTURE_MOUNT=present FIXTURE_SOURCE=fixture/root ;;
    ambiguous) export FIXTURE_MOUNT=present FIXTURE_SOURCE=$'fixture/runtime/docker\nfixture/root' ;;
  esac
  if bash "$source_file" /var/lib/forgejo-docker fixture/runtime/docker >"$fixture/out" 2>&1; then
    echo "Storage check accepted $mode mount identity" >&2
    exit 1
  fi
done
echo 'CI runtime storage identity checks passed.'
