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

    if ($5 == root_path) {
      root_count++
      root_id = mount_id
      for (field = 7; field <= NF && $field != "-"; field++) {
        if ($field ~ /^shared:[0-9]+$/) {
          shared[mount_id] = 1
        }
      }
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

    if (!shared[root_id]) {
      report("/run/netns is not a shared mount")
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
