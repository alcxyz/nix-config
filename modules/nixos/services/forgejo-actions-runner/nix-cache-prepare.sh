# Expose the persistent CI Nix store read-only to job containers and create
# the drop directory for path lists (ADR-0109). Runs as root before the
# Podman API. It writes nothing inside the filler-owned store: the store's
# own directories and empty snapshot come from INIT, run as the filler.
#
# Every mount jobs can see is assembled, made read-only and checked in a
# root-only staging directory, then moved into place, so the published path
# is never writable. `stop` leaves an empty read-only placeholder there.
#
# Usage: forgejo-nix-cache-prepare start|stop DATA EXPOSED DROP DROP_SIZE FILLER BUILDER BUILDER_GROUP INIT
action=$1
data=$2
exposed=$3
drop=$4
drop_size=$5
filler=$6
builder=$7
builder_group=$8
init=$9
stage=/run/forgejo-nix-cache-stage
parent=${data%/*}
name=${data##*/}

filler_uid=$(id -u "$filler")
filler_gid=$(id -g "$filler")
builder_uid=$(id -u "$builder")
builder_gid=$(getent group "$builder_group" | cut -d: -f3)

# Path lists from jobs: a small tmpfs, sticky and writable by all but
# listable only by the filler. It is not private between jobs: every job
# runs as the same host user, which can open, replace or delete another
# job's list by name, so lists carry only public store paths and lock
# files. It exists whatever becomes of the cache below, and its mode is
# restored on every run.
[[ -d $drop ]] || mkdir -m 0755 -- "$drop"
if ! mountpoint -q -- "$drop"; then
  mount -t tmpfs -o "size=$drop_size,nosuid,nodev,noexec" tmpfs "$drop"
fi
chown "$filler_uid:$filler_gid" -- "$drop"
chmod 1733 -- "$drop"
[[ -d $exposed ]] || mkdir -m 0755 -- "$exposed"

is_read_only() {
  findmnt -rn -o OPTIONS --mountpoint "$1" | tr ',' '\n' | grep -qx ro
}

# A private, root-only tmpfs: mounts made in it neither propagate to the
# API's namespace nor can be reached by anyone else until they are moved.
prepare_stage() {
  [[ -d $stage ]] || mkdir -m 0700 -- "$stage"
  if ! mountpoint -q -- "$stage"; then
    mount -t tmpfs -o size=1M,mode=0700,nosuid,nodev,noexec tmpfs "$stage"
  fi
  mount --make-private -- "$stage"
  chown 0:0 -- "$stage"
  chmod 0700 -- "$stage"
  [[ -d $stage/m ]] || mkdir -m 0700 -- "$stage/m"
  while mountpoint -q -- "$stage/m"; do umount --lazy -- "$stage/m"; done
}
# Replace whatever is published by the finished, read-only staged mount.
publish() {
  is_read_only "$stage/m" || exit 1
  while mountpoint -q -- "$exposed"; do umount --lazy -- "$exposed"; done
  mount --move -- "$stage/m" "$exposed"
}
# An empty read-only placeholder with the same paths, so jobs that bind
# them still start and fall back to installing Nix.
placeholder() {
  prepare_stage
  mount -t tmpfs -o size=1M,mode=0755,nosuid,nodev,noexec tmpfs "$stage/m"
  mkdir -p -- "$stage/m/nix/store" "$stage/m/job"
  mount -o remount,ro,nosuid,nodev,noexec -- "$stage/m"
  publish
}
refuse() {
  printf 'nix_cache_refused reason=%s path=%s\n' "$1" "$data" >&2
  placeholder
  exit 1
}

if [[ $action == stop ]]; then
  placeholder
  printf 'nix_cache_placeholder path=%s\n' "$exposed"
  exit 0
fi

# Every ancestor of the store must be a directory that only root can
# change, so nobody else can plant a link or swap a directory on the path.
root_only() {
  local path=$1 info
  while :; do
    info=$(stat -c '%u %a %F' -- "$path") || return 1
    read -r uid mode type <<<"$info"
    [[ $uid == 0 && $type == directory && $((8#$mode & 8#022)) == 0 ]] || return 1
    [[ $path != / ]] || return 0
    path=${path%/*}
    path=${path:-/}
  done
}
existing=$parent
while [[ ! -e $existing && ! -L $existing ]]; do
  existing=${existing%/*}
  existing=${existing:-/}
done
root_only "$existing" || refuse parent_not_root_only
[[ -d $parent ]] || mkdir -p -- "$parent"
root_only "$parent" || refuse parent_not_root_only

# Create and validate through descriptors, and expose exactly the inode
# that was validated.
if ! { exec {parent_fd}<"$parent/."; } 2>/dev/null; then refuse unopenable; fi
at=/proc/self/fd/$parent_fd
if [[ ! -e $at/$name && ! -L $at/$name ]]; then
  mkdir -m 0755 -- "$at/$name"
  chown -h "$filler_uid:$filler_gid" -- "$at/$name"
fi
[[ ! -L $at/$name ]] || refuse symlink
if ! { exec {cache_fd}<"$at/$name/."; } 2>/dev/null; then refuse unopenable; fi
cache=/proc/self/fd/$cache_fd
identity=$(stat -L -c '%d:%i' -- "$cache")
[[ $identity == "$(stat -c '%d:%i' -- "$at/$name")" ]] || refuse moved
[[ $(stat -L -c '%u:%g:%a:%F' -- "$cache") == "$filler_uid:$filler_gid:755:directory" ]] || refuse owner

# The filler, unprivileged, creates the bind sources of a fresh cache: an
# empty store and an empty database snapshot, but no Nix until its first
# fill. Root only reads what it made.
setpriv --reuid="$filler_uid" --regid="$filler_gid" --clear-groups \
  --inh-caps=-all --bounding-set=-all --no-new-privs -- "$init" "$data" || refuse init_failed
for sub in nix nix/store job; do
  [[ $(stat -c '%u:%g:%F' -- "$cache/$sub") == "$filler_uid:$filler_gid:directory" ]] || refuse owner
done

# Jobs see the store through a read-only, ID-mapped bind under root-owned
# /run: the filler's files appear as the API user's, which is root in the
# job's user namespace, so Nix in a job can replace a lower path its
# database does not list (an overlay copy-up in its RAM upper) while the
# store itself stays untouched. A container that binds it again gets a
# locked read-only mount, and the builder cannot rename or replace a mount
# there. Any other mount, such as an earlier placeholder, is replaced.
exposed_ok() {
  [[ $(stat -c '%d:%i:%u:%g' -- "$exposed") == "$identity:$builder_uid:$builder_gid" ]] && is_read_only "$exposed"
}
staged_ok() {
  [[ $(stat -c '%d:%i:%u:%g' -- "$stage/m") == "$identity:$builder_uid:$builder_gid" ]] && is_read_only "$stage/m"
}
if ! { mountpoint -q -- "$exposed" && exposed_ok; }; then
  prepare_stage
  mount --no-canonicalize --bind \
    -o "X-mount.idmap=u:$filler_uid:$builder_uid:1 g:$filler_gid:$builder_gid:1" -- "$cache" "$stage/m"
  mount -o remount,bind,ro,nosuid,nodev -- "$stage/m"
  staged_ok || refuse "not_staged found=$(stat -c '%d:%i:%u:%g' -- "$stage/m")"
  publish
fi
exposed_ok || refuse "not_exposed found=$(stat -c '%d:%i:%u:%g' -- "$exposed") wanted=$identity:$builder_uid:$builder_gid"
printf 'nix_cache_exposed data=%s path=%s drop=%s\n' "$data" "$exposed" "$drop"
