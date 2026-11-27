# Print one line per pressure resource and one per physical disk, then wait.
# Only bash builtins run inside the loop apart from sleep, so a sample costs
# one fork even when the host is under memory pressure.
interval="$1"

while :; do
  for resource in cpu io memory; do
    line="psi $resource"
    while read -r kind fields; do
      line+=" $kind $fields"
    done <"/proc/pressure/$resource"
    printf '%s\n' "$line"
  done

  # Whole disks backed by a device: partitions, loop, zram, dm and md
  # devices have no device link under /sys/block.
  while read -r _ _ name stats; do
    [[ -e /sys/block/$name/device ]] || continue
    printf 'disk %s %s\n' "$name" "$stats"
  done </proc/diskstats

  sleep "$interval"
done
