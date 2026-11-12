#!/usr/bin/env bash
set -euo pipefail

# Root ExecStartPre of the Podman CI API when its volumes are in RAM
# (ADR-0108). Makes a fresh ext4 filesystem on a zram block device at every
# API start and mounts it where the API keeps its volumes, so that BuildKit's
# overlay snapshotter, which leaves out the "userxattr" option on tmpfs, sees
# ext4 and keeps it, while nothing goes to the SSD.
#
# The API runs a transient store whose volume metadata lives in the runroot
# that systemd removes when the API stops, so the volumes an earlier API left
# are unreferenced: unmounting and resetting the device frees all of their
# memory at once. The device's size is its memory reservation: zram stores
# each page in at most a page and has no mem_limit, so a full filesystem
# returns "No space left on device" rather than I/O errors. After many frees
# zsmalloc can hold more until it is compacted, which the kernel does under
# memory pressure and the store reset at each check (ADR-0108). Mounted
# with discard, deleted files return their memory.
#
# Refuses the start unless the result is exactly that filesystem on this
# unit's own device: volumes never land on whatever is under the mount point.
# It also refuses while anything still holds the last filesystem, such as a
# process with a file open or its working directory on it, or another mount
# namespace that still mounts it, and names the holders: the device cannot
# be reset then, and a second device would set aside memory that CI's limits
# do not account for. Nothing retries the API (Restart=no), and runners
# restart skips failed units: once the holder is gone, start the API and the
# pool runners again with systemctl start (ADR-0108).
#
# Last, it writes this start's systemd invocation ID to the started file, so
# that the store reset checks the filesystem only while the running API uses
# it, not after a deploy that has not restarted the API yet (ADR-0105).

mount_point=${1:?mount point required}
size=${2:?size required}
started=${3:?started file required}
owner=${VOLUMES_OWNER:-forgejo-podman-builder}
group=${VOLUMES_GROUP:-forgejo-podman}
# The device an earlier start set up, so that each start reuses it.
record=${VOLUMES_DEVICE_RECORD:-/run/forgejo-podman-volumes.device}
volumes=$mount_point/volumes

refuse() {
  echo "Podman volume filesystem: $*; refusing to start." >&2
  exit 1
}

[[ $mount_point == /*/* && $mount_point != */ ]] || refuse "invalid mount point $mount_point"
[[ $size =~ ^([1-9][0-9]*)([MG])$ ]] || refuse "invalid size $size"
bytes=${BASH_REMATCH[1]}
if [[ ${BASH_REMATCH[2]} == G ]]; then bytes=$((bytes << 30)); else bytes=$((bytes << 20)); fi
# A link could lead the mount, and the volumes, onto a disk.
[[ ! -L $mount_point ]] || refuse "$mount_point is a symbolic link"
[[ $started == /*/* && $started != */ ]] || refuse "invalid started file $started"
invocation=${INVOCATION_ID:-}
[[ $invocation =~ ^[0-9a-f]{32}$ ]] || refuse "no systemd invocation ID"
# Until this start has made the filesystem, no API uses it.
rm -f -- "$started"

# A process's name: the file name of its command, which comm truncates and
# for some starts replaces with a store path, else its comm.
name() {
  local argv0=
  { IFS= read -r -d '' argv0 <"/proc/$1/cmdline"; } 2>/dev/null || true
  if [[ -n $argv0 ]]; then
    printf '%s' "${argv0##*/}"
  else
    cat "/proc/$1/comm" 2>/dev/null || printf gone
  fi
}

# The processes, in any mount namespace, that use a file on the mounted
# filesystem and so keep its unmount busy, as "PID (command)": a working or
# root directory, an executable, an open file or a memory map in it (fuser).
users() {
  local pid found=()
  # fuser takes no "--"; the mount point is an absolute path.
  for pid in $(fuser -M -m "$mount_point" 2>/dev/null); do
    [[ $pid =~ ^[0-9]+$ ]] || continue
    found+=("$pid ($(name "$pid"))")
  done
  printf '%s' "${found[*]:-none found}"
}

# The processes in other mount namespaces that still mount the device, one
# per namespace, as "PID (command)". Asked once the unmount here has
# succeeded, which also removed the copies that services with their own
# mount namespace received by propagation, so only copies the unmount did
# not reach are left.
holders() {
  local majmin own file pid ns seen=' ' found=()
  majmin=$(<"/sys/block/$1/dev")
  own=$(readlink /proc/self/ns/mnt)
  for file in /proc/[0-9]*/mountinfo; do
    pid=${file#/proc/}
    pid=${pid%/mountinfo}
    ns=$(readlink "/proc/$pid/ns/mnt" 2>/dev/null) || continue
    [[ $ns != "$own" && $seen != *" $ns "* ]] || continue
    grep -Eq "^[0-9]+ [0-9]+ $majmin " "$file" 2>/dev/null || continue
    seen+="$ns "
    found+=("$pid ($(name "$pid"))")
  done
  printf '%s' "${found[*]:-none found}"
}

device=
if [[ -f $record && ! -L $record ]]; then
  device=$(<"$record")
  [[ $device =~ ^zram[0-9]+$ && -d /sys/block/$device ]] || device=
fi

# Release the filesystem an earlier start mounted; anything else there stays
# and keeps the API from starting.
if mountpoint -q -- "$mount_point"; then
  source=$(findmnt -rn --mountpoint "$mount_point" -o SOURCE)
  [[ -n $device && $source == "/dev/$device" ]] ||
    refuse "$mount_point holds $source, not this unit's zram device"
  umount -- "$mount_point" ||
    refuse "$mount_point is busy, held by processes: $(users); start forgejo-runner-podman.service and the forgejo-podman-runner services again once they are gone"
fi

modprobe zram
if [[ -z $device ]]; then
  # A device of its own, never zram0, which zram swap takes.
  id=$(</sys/class/zram-control/hot_add)
  [[ $id =~ ^[0-9]+$ ]] || refuse "no zram device"
  device=zram$id
  printf '%s\n' "$device" >"$record"
fi
# Never a device that something else uses.
! findmnt -rn --source "/dev/$device" >/dev/null || refuse "/dev/$device is mounted elsewhere"
! grep -q "^/dev/$device " /proc/swaps || refuse "/dev/$device is a swap device"
# Frees whatever the device held; a device just added holds nothing and
# needs no reset. The reset fails with EBUSY while anything still has the
# device open: briefly a udev probe after the unmount above, else a mount
# namespace that a process made before this start, which keeps the
# filesystem mounted after that unmount. A few tries ride out the first.
if [[ $(<"/sys/block/$device/disksize") != 0 ]]; then
  for try in 1 2 3 4 5; do
    { echo 1 >"/sys/block/$device/reset"; } 2>/dev/null && break
    ((try < 5)) ||
      refuse "/dev/$device is still open, held by another mount namespace (processes: $(holders "$device")); start forgejo-runner-podman.service and the forgejo-podman-runner services again once they are gone"
    sleep 1
  done
fi
# lz4 is fast enough for CI I/O; the kernel's default stays when it lacks it.
echo lz4 >"/sys/block/$device/comp_algorithm" 2>/dev/null || true
echo "$bytes" >"/sys/block/$device/disksize"
# Throwaway data, made again at each start: no journal, which would only add
# writes and an abort that turns the filesystem read-only; no blocks reserved
# for root; page-sized blocks, so discards free whole zram pages; an inode
# per block, since every non-empty file and directory takes a block, so the
# bytes run out before the inodes unless a job makes many empty files or
# short symbolic links (ADR-0108). On an ext4 error it turns read-only: jobs fail visibly, and the
# store reset makes it again (ADR-0105).
mkfs.ext4 -q -F -b 4096 -m 0 -i 4096 -O ^has_journal -E nodiscard,lazy_itable_init=0 \
  -L forgejo-volumes "/dev/$device"
install -d -m 0755 -- "$mount_point"
mount -t ext4 -o discard,errors=remount-ro -- "/dev/$device" "$mount_point"
install -d -m 0700 -o "$owner" -g "$group" -- "$volumes"

[[ $(findmnt -rn --mountpoint "$mount_point" -o FSTYPE,SOURCE) == "ext4 /dev/$device" ]] ||
  refuse "$mount_point is not ext4 on /dev/$device"
options=,$(findmnt -rn --mountpoint "$mount_point" -o OPTIONS),
[[ $options == ,rw,* && $options == *,discard,* ]] || refuse "$mount_point is mounted with $options"
[[ $(<"/sys/block/$device/disksize") == "$bytes" ]] || refuse "/dev/$device is not $size"
printf '%s\n' "$invocation" >"$started"
echo "Volumes are on a fresh ext4 on /dev/$device ($size of RAM) at $mount_point."
