set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "xyz-local-backup must run as root" >&2
  exit 1
fi

if [ "$#" -ne 1 ]; then
  echo "usage: xyz-local-backup {appstate|k8s}" >&2
  exit 64
fi

backup_name="$1"

export PATH=@path@

target_pool=@backup_pool@

if ! zpool list -H "$target_pool" >/dev/null 2>&1; then
  echo "backup pool '$target_pool' is not imported; create/import it before running local backups" >&2
  exit 1
fi

target_pool_encryption="$(zfs get -H -o value encryption "$target_pool" 2>/dev/null || echo off)"
if [ "$target_pool_encryption" = off ]; then
  echo "backup pool '$target_pool' is not encrypted; refusing to write unencrypted local backups" >&2
  exit 1
fi

target_pool_keystatus="$(zfs get -H -o value keystatus "$target_pool" 2>/dev/null || echo unavailable)"
if [ "$target_pool_keystatus" != available ]; then
  echo "backup pool '$target_pool' key is not loaded; run: zfs load-key $target_pool" >&2
  exit 1
fi

lock_dir=/run/lock
mkdir -p "$lock_dir"
exec 9>"$lock_dir/xyz-local-backup-@lock_label@.lock"
echo "waiting for @lock_label@ backup lock for $backup_name"
flock 9
echo "acquired @lock_label@ backup lock for $backup_name"

ensure_backup_dataset() {
  local target_dataset="$1"

  if ! zfs list -H "$target_dataset" >/dev/null 2>&1; then
    zfs create -p \
      -o mountpoint=none \
      -o canmount=off \
      -o compression=zstd \
      -o atime=off \
      "$target_dataset"
  fi

  target_dataset_encryption="$(zfs get -H -o value encryption "$target_dataset" 2>/dev/null || echo off)"
  if [ "$target_dataset_encryption" = off ]; then
    echo "backup dataset '$target_dataset' is not encrypted; refusing to write unencrypted local backups" >&2
    exit 1
  fi

  target_dataset_keystatus="$(zfs get -H -o value keystatus "$target_dataset" 2>/dev/null || echo unavailable)"
  if [ "$target_dataset_keystatus" != available ]; then
    echo "backup dataset '$target_dataset' key is not loaded; run: zfs load-key $target_dataset" >&2
    exit 1
  fi
}

replicate_dataset() {
  local source_dataset="$1"
  local target_dataset="$2"
  local mode="$3"

  if ! zfs list -H "$source_dataset" >/dev/null 2>&1; then
    echo "source dataset '$source_dataset' does not exist" >&2
    exit 1
  fi

  ensure_backup_dataset "$target_dataset"

  syncoid_args=(
    --recursive
    --compress=none
    --recvoptions="u o canmount=off o readonly=on"
  )
  if [ "$mode" = skip-parent ]; then
    syncoid_args+=(--skip-parent)
  fi

  if [ "$mode" = include-parent ]; then
    target_snapshot_count="$(zfs list -H -t snapshot -o name -r "$target_dataset" 2>/dev/null | wc -l)"
    target_referenced_bytes="$(zfs get -Hp -o value referenced "$target_dataset" 2>/dev/null || echo 0)"

    if [ "$target_snapshot_count" -eq 0 ]; then
      if [ "$target_referenced_bytes" -gt 1048576 ]; then
        echo "target dataset '$target_dataset' has no snapshots but references data; refusing initial seed" >&2
        exit 1
      fi

      syncoid_args+=(--force-delete)
    fi
  fi

  syncoid \
    "${syncoid_args[@]}" \
    "$source_dataset" \
    "$target_dataset"
}

case "$backup_name" in
  appstate)
    @app_state_replication_commands@
    ;;
  k8s)
    replicate_dataset @k8s_backup_dataset@ @k8s_backup_root@ include-parent
    ;;
  *)
    echo "unknown backup target '$backup_name'; expected appstate or k8s" >&2
    exit 64
    ;;
esac
