#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: container-netns-audit [MOUNTINFO]" >&2
  exit 2
fi

mountinfo=${1:-/proc/self/mountinfo}
if [[ ! -r $mountinfo ]]; then
  echo "container netns audit: cannot read $mountinfo" >&2
  exit 1
fi

awk '
  BEGIN {
    root_path = "/run/netns"
  }

  {
    mount_id = $1
    parents[mount_id] = $2
    paths[mount_id] = $5

    for (field = 7; field <= NF && $field != "-"; field++) {
      if ($field ~ /^shared:[0-9]+$/) {
        split($field, shared_field, ":")
        shared_id[mount_id] = shared_field[2]
      }
    }

    if ($5 == root_path) {
      root_count++
      root_id = mount_id
    } else if (index($5, root_path "/") == 1) {
      descendants[mount_id] = $5
    }
  }

  function report(message) {
    print "container netns audit: " message > "/dev/stderr"
    failed = 1
  }

  END {
    if (root_count != 1) {
      report("expected exactly one /run/netns mount, found " (root_count + 0))
      exit 1
    }

    if (!(root_id in shared_id)) {
      report("/run/netns is not a shared mount")
    }

    current = parents[root_id]
    delete visited
    while (current in parents) {
      if (visited[current]++) {
        report("/run/netns has a mount-parent cycle")
        break
      }
      if ((root_id in shared_id) && (current in shared_id) && shared_id[current] == shared_id[root_id]) {
        report("/run/netns shares a propagation peer group with ancestor " paths[current])
        break
      }
      parent = parents[current]
      if (parent == current) {
        break
      }
      current = parent
    }

    for (mount_id in descendants) {
      current = mount_id
      delete visited
      while (current != root_id) {
        if (visited[current]++) {
          report(descendants[mount_id] " has a mount-parent cycle")
          break
        }
        if (!(current in parents)) {
          report(descendants[mount_id] " is outside the /run/netns mount subtree")
          break
        }
        parent = parents[current]
        if (parent == current) {
          report(descendants[mount_id] " is outside the /run/netns mount subtree")
          break
        }
        current = parent
      }
    }

    if (failed) {
      exit 1
    }
    print "container netns audit: shared mount topology is healthy"
  }
' "$mountinfo"
