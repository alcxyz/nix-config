#!/usr/bin/env bash
set -euo pipefail

# Root ExecStartPre of the Podman CI API when its graphroot is RAM scratch
# (#1027, ADR-0108). Refuses the start unless the scratch tmpfs is mounted, so
# scratch never lands on the filesystem under the mount point. Empties the
# whole tmpfs: the API runs a transient store, whose container and volume
# metadata live in the runroot that systemd removes when the API stops, so
# whatever an earlier API left there is unreferenced, and so is trash that an
# interrupted store reset left behind. Then moves a
# disk store from before scratch, which holds
# containers and volumes besides images, aside under the reset's trash name.
# The store reset's next check deletes that trash at the lowest priority
# (ADR-0105), and the image store starts empty.
#
# Volumes live on disk beside the image store, not in the scratch: BuildKit
# (containerd's overlay snapshotter) leaves out the "userxattr" option when
# its state is on tmpfs, and its overlays in the rootless user namespace then
# fail dpkg's directory renames with EXDEV (ADR-0108). Their metadata went
# with the runroot as well, so volumes an earlier API left behind are moved
# aside under the same trash name for the reset to delete.

scratch=${1:?scratch mount point required}
graph_root=${2:?graphroot required}
store=${3:?disk store required}
volumes=${4:?volume directory required}
owner=${SCRATCH_OWNER:-forgejo-podman-builder}
group=${SCRATCH_GROUP:-forgejo-podman}

[[ $(findmnt -rn --mountpoint "$scratch" -o FSTYPE) == tmpfs ]] || {
  echo "Podman scratch tmpfs is not mounted at $scratch." >&2
  exit 1
}
[[ $graph_root == "$scratch"/* && ! -L $graph_root ]] || exit 1
# Beside the store, so its trash is on the filesystem the reset cleans.
[[ ${volumes%/*} == "${store%/*}" && $volumes != "$store" && ! -L $volumes ]] || exit 1
find "$scratch" -mindepth 1 -maxdepth 1 -exec rm -rf --one-file-system -- {} +
install -d -m 0700 -o "$owner" -g "$group" -- "$graph_root"

# An image store never has these; a graphroot from before scratch does.
if [[ -d $store && ! -L $store ]]; then
  for marker in libpod overlay-containers volumes db.sql bolt_state.db; do
    if [[ -e $store/$marker ]]; then
      trash=${store%/*}/.${store##*/}.trash.$(date +%s)
      [[ ! -e $trash ]] || exit 1
      mv -T -- "$store" "$trash"
      sync -- "${store%/*}"
      echo "Moved the pre-scratch store aside as $trash; the store reset deletes it."
      break
    fi
  done
fi

if [[ -d $volumes ]] && [[ -n $(find "$volumes" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
  trash=${store%/*}/.${store##*/}.trash.$(date +%s).volumes
  [[ ! -e $trash ]] || exit 1
  mv -T -- "$volumes" "$trash"
  sync -- "${store%/*}"
  echo "Moved the volumes an earlier API left aside as $trash; the store reset deletes them."
fi
install -d -m 0700 -o "$owner" -g "$group" -- "$volumes"
