set -euo pipefail

export PATH=@path@

dataset=@games_dataset@
mountpoint=@games_mountpoint@
pool=@games_pool@

if ! zpool list -H "$pool" >/dev/null 2>&1; then
  echo "games pool '$pool' is not imported" >&2
  exit 1
fi

pool_encryption="$(zfs get -H -o value encryption "$pool" 2>/dev/null || echo off)"
pool_keystatus="$(zfs get -H -o value keystatus "$pool" 2>/dev/null || echo unavailable)"
if [ "$pool_encryption" != off ] && [ "$pool_keystatus" != available ]; then
  echo "games pool '$pool' key is not loaded; run: zfs load-key $pool" >&2
  exit 1
fi

install -d -m 0755 "$(dirname "$mountpoint")"

if ! zfs list -H "$dataset" >/dev/null 2>&1; then
  zfs create -p \
    -o mountpoint="$mountpoint" \
    -o compression=lz4 \
    -o atime=off \
    "$dataset"
else
  current_mountpoint="$(zfs get -H -o value mountpoint "$dataset")"
  if [ "$current_mountpoint" != "$mountpoint" ]; then
    zfs set mountpoint="$mountpoint" "$dataset"
  fi
  zfs set compression=lz4 "$dataset"
  zfs set atime=off "$dataset"
fi

current_source="$(findmnt -rn -o SOURCE --mountpoint "$mountpoint" 2>/dev/null || true)"
if [ -n "$current_source" ] && [ "$current_source" != "$dataset" ]; then
  echo "$mountpoint is already mounted from '$current_source', expected '$dataset'" >&2
  exit 1
fi

if [ -z "$current_source" ]; then
  zfs mount "$dataset"
fi
[ "$(findmnt -rn -o SOURCE --mountpoint "$mountpoint")" = "$dataset" ] || {
  echo "$mountpoint is not mounted from '$dataset'" >&2
  exit 1
}
chown root:media "$mountpoint"
chmod 0770 "$mountpoint"
