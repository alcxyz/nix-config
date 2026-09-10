set -euo pipefail

export PATH=@path@

pool=@runtime_pool@
if [ "$(zpool list -H -o health "$pool" 2>/dev/null || true)" != ONLINE ]; then
  echo "runtime pool '$pool' is unavailable or unhealthy" >&2
  exit 1
fi

zpool set autotrim=off "$pool"

for dataset in \
  @docker_dataset@ \
  @steam_headless_dataset@; do
  if ! zfs list -H "$dataset" >/dev/null 2>&1; then
    echo "required runtime dataset '$dataset' is missing" >&2
    exit 1
  fi
  zfs set compression=zstd atime=off xattr=sa acltype=posixacl "$dataset"
done

zfs set quota=100G @docker_dataset@
zfs set quota=40G refreservation=20G @steam_headless_dataset@

forgejo_docker_dataset=@forgejo_docker_dataset@
forgejo_docker_quota=@forgejo_docker_quota@
if [ -n "$forgejo_docker_dataset" ]; then
  if ! zfs list -H "$forgejo_docker_dataset" >/dev/null 2>&1; then
    echo "required runtime dataset '$forgejo_docker_dataset' is missing" >&2
    exit 1
  fi
  forgejo_docker_mountpoint="$(zfs get -H -o value mountpoint "$forgejo_docker_dataset")"
  if [ "$forgejo_docker_mountpoint" != legacy ]; then
    echo "runtime dataset '$forgejo_docker_dataset' has mountpoint '$forgejo_docker_mountpoint', expected 'legacy'" >&2
    exit 1
  fi
  zfs set \
    compression=zstd \
    atime=off \
    xattr=sa \
    acltype=posixacl \
    quota="$forgejo_docker_quota" \
    "$forgejo_docker_dataset"
fi

retired_k3s_dataset=@retired_k3s_dataset@
if zfs list -H "$retired_k3s_dataset" >/dev/null 2>&1; then
  zfs set canmount=noauto "$retired_k3s_dataset"
  if [ "$(zfs get -H -o value mounted "$retired_k3s_dataset")" = yes ]; then
    mounted_source="$(findmnt -rn -o SOURCE --target /var/lib/rancher/k3s 2>/dev/null || true)"
    if [ "$mounted_source" != "$retired_k3s_dataset" ]; then
      echo "/var/lib/rancher/k3s is mounted from '$mounted_source', expected '$retired_k3s_dataset'" >&2
      exit 1
    fi
    umount /var/lib/rancher/k3s
  fi
fi

check_mount() {
  local mountpoint="$1"
  local expected="$2"
  local source

  source="$(findmnt -rn -o SOURCE --target "$mountpoint" 2>/dev/null || true)"
  if [ "$source" != "$expected" ]; then
    echo "$mountpoint is mounted from '$source', expected '$expected'" >&2
    exit 1
  fi
}

check_mount /var/lib/docker @docker_dataset@
check_mount /var/lib/steam-headless @steam_headless_dataset@
if [ -n "$forgejo_docker_dataset" ]; then
  check_mount /var/lib/forgejo-docker "$forgejo_docker_dataset"
fi
