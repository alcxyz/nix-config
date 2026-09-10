#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
  echo 'Usage: test-xyz-runtime-storage-policy.sh POLICY_SOURCE' >&2
  exit 2
fi

policy_source=$1
fixture_root=$(mktemp -d)
trap 'rm -rf "$fixture_root"' EXIT
fixture_bin="$fixture_root/bin"
fixture_log="$fixture_root/operations.log"
mkdir -p "$fixture_bin"
bash_path=$(command -v bash)

cat >"$fixture_bin/zpool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = list ]; then
  printf '%s\n' ONLINE
  exit 0
fi
printf 'zpool %s\n' "$*" >>"$FIXTURE_LOG"
EOF

cat >"$fixture_bin/zfs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  list)
    exit 0
    ;;
  get)
    property=$5
    dataset=$6
    if [ "$property" = mountpoint ] && [ "$dataset" = fixturepool/runtime/forgejo-docker ]; then
      printf '%s\n' "${FORGEJO_MOUNTPOINT:-legacy}"
    elif [ "$property" = mounted ] && [ "$dataset" = fixturepool/runtime/k3s ]; then
      printf '%s\n' no
    else
      echo "unexpected zfs get: $*" >&2
      exit 1
    fi
    ;;
  set)
    printf 'zfs %s\n' "$*" >>"$FIXTURE_LOG"
    ;;
  *)
    echo "unexpected zfs command: $*" >&2
    exit 1
    ;;
esac
EOF

cat >"$fixture_bin/findmnt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${*: -1}" in
  /var/lib/docker) printf '%s\n' fixturepool/runtime/docker ;;
  /var/lib/steam-headless) printf '%s\n' fixturepool/appstate/steam-headless ;;
  /var/lib/forgejo-docker) printf '%s\n' fixturepool/runtime/forgejo-docker ;;
  *) exit 1 ;;
esac
EOF

cat >"$fixture_bin/umount" <<'EOF'
#!/usr/bin/env bash
echo 'unexpected umount' >&2
exit 1
EOF
for helper in "$fixture_bin"/*; do
  sed -i "1s|.*|#!$bash_path|" "$helper"
done
chmod +x "$fixture_bin"/*

sed \
  -e "s|@path@|$fixture_bin:$PATH|g" \
  -e 's|@runtime_pool@|fixturepool|g' \
  -e 's|@docker_dataset@|fixturepool/runtime/docker|g' \
  -e 's|@steam_headless_dataset@|fixturepool/appstate/steam-headless|g' \
  -e 's|@forgejo_docker_dataset@|fixturepool/runtime/forgejo-docker|g' \
  -e 's|@forgejo_docker_quota@|50G|g' \
  -e 's|@retired_k3s_dataset@|fixturepool/runtime/k3s|g' \
  "$policy_source" >"$fixture_root/policy"
chmod +x "$fixture_root/policy"

FIXTURE_LOG="$fixture_log" "$fixture_root/policy"
if rg -q '^zfs set .*mountpoint=' "$fixture_log"; then
  echo 'runtime policy rewrote a ZFS mountpoint' >&2
  exit 1
fi
rg -q '^zfs set .*quota=50G fixturepool/runtime/forgejo-docker$' "$fixture_log"

: >"$fixture_log"
if FORGEJO_MOUNTPOINT=/var/lib/forgejo-docker FIXTURE_LOG="$fixture_log" \
  "$fixture_root/policy" >"$fixture_root/mismatch.out" 2>"$fixture_root/mismatch.err"; then
  echo 'runtime policy accepted a non-legacy Forgejo Docker mountpoint' >&2
  exit 1
fi
rg -q "has mountpoint '/var/lib/forgejo-docker', expected 'legacy'" "$fixture_root/mismatch.err"
if rg -q '^zfs set .*fixturepool/runtime/forgejo-docker$' "$fixture_log"; then
  echo 'runtime policy mutated the Forgejo Docker dataset after an invariant failure' >&2
  exit 1
fi
