#!/usr/bin/env bash
set -euo pipefail

SWAPFILE="/ext4/swap64G"
SWAPSIZE="64G"

usage() {
  cat <<EOF
Usage: $(basename "$0") [on|off]

 on   – create & enable a ${SWAPSIZE} swapfile at ${SWAPFILE}
 off  – disable & remove that swapfile
EOF
}

if [ "$#" -ne 1 ]; then
  usage; exit 1
fi

case "$1" in
  on)
    # If it's already enabled, nothing to do
    if sudo swapon --show=NAME | grep -q "^${SWAPFILE}\$"; then
      echo "Swap already enabled on ${SWAPFILE}"
      exit 0
    fi

    # Create the file if it doesn't exist
    if [ ! -f "${SWAPFILE}" ]; then
      echo "Creating ${SWAPSIZE} swapfile at ${SWAPFILE}..."
      sudo fallocate -l "${SWAPSIZE}" "${SWAPFILE}"
      sudo chmod 600 "${SWAPFILE}"
      sudo mkswap "${SWAPFILE}"
    else
      echo "Swapfile exists at ${SWAPFILE}, just enabling..."
    fi

    echo "Enabling swap..."
    sudo swapon "${SWAPFILE}"
    echo "✅ Swap is now ON."
    ;;

  off)
    # If it's enabled, turn it off
    if sudo swapon --show=NAME | grep -q "^${SWAPFILE}\$"; then
      echo "Disabling swap on ${SWAPFILE}..."
      sudo swapoff "${SWAPFILE}"
    else
      echo "Swap not enabled on ${SWAPFILE}"
    fi

    # Remove the file if it exists
    if [ -f "${SWAPFILE}" ]; then
      echo "Removing swapfile ${SWAPFILE}..."
      sudo rm -f "${SWAPFILE}"
      echo "✅ Swapfile removed."
    fi
    ;;

  *)
    usage; exit 1
    ;;
esac
