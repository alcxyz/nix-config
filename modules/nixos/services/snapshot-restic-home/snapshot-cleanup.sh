# Temporary snapshot cleanup for snapshot-restic-home.
# Callers set snapshot_dataset, snapshot_mountpoint, destroy_attempts and
# destroy_retry_delay before calling these functions.

# Only snapshots named by the backup script are ever destroyed here; the sweep
# also requires the ownership property the backup script sets on creation.
snapshot_name_pattern='^restic-[0-9]{8}T[0-9]{6}Z-[0-9]+$'
snapshot_owner_property="snapshot-restic-home:temporary"

# Destroy one service-owned snapshot, retrying while ZFS reports it busy.
destroy_snapshot() {
  local name=$1
  local snapshot="$snapshot_dataset@$name"
  local automount="$snapshot_mountpoint/.zfs/snapshot/$name"
  local attempt=1

  if ! [[ $name =~ $snapshot_name_pattern ]]; then
    echo "refusing to destroy snapshot not owned by this service: $snapshot" >&2
    return 1
  fi

  while true; do
    # The snapshot's .zfs automount can keep it busy right after use.
    if findmnt -rn --mountpoint "$automount" >/dev/null 2>&1; then
      umount "$automount" || true
    fi
    if zfs destroy "$snapshot"; then
      return 0
    fi
    # A snapshot removed by someone else needs no further cleanup.
    if ! zfs list -H -t snapshot -o name "$snapshot" >/dev/null 2>&1; then
      return 0
    fi
    if [ "$attempt" -ge "$destroy_attempts" ]; then
      echo "failed to destroy temporary snapshot after $attempt attempts: $snapshot" >&2
      return 1
    fi
    attempt=$((attempt + 1))
    sleep "$destroy_retry_delay"
  done
}

# Destroy snapshots left behind by earlier runs whose cleanup failed.
sweep_leftover_snapshots() {
  local snapshots entry owner name failed=0

  snapshots="$(zfs list -H -t snapshot -o "name,$snapshot_owner_property" -d 1 "$snapshot_dataset")" || return 1
  while IFS=$'\t' read -r entry owner <&3; do
    [ -n "$entry" ] || continue
    [ "${entry%%@*}" = "$snapshot_dataset" ] || continue
    [ "$owner" = true ] || continue
    name=${entry#*@}
    [[ $name =~ $snapshot_name_pattern ]] || continue
    echo "destroying leftover temporary snapshot: $entry" >&2
    destroy_snapshot "$name" || failed=1
  done 3<<<"$snapshots"
  return "$failed"
}
