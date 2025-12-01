#!/usr/bin/env nu
# scripts/swap.nu — toggle a temporary 64 GiB swapfile at /swap64G

def usage [] {
  echo "Usage: swap.nu [on|off]"
}

let swapfile = "/swap64G"
let args     = $argv

# must get exactly one argument
if ( ($args | length) != 1 ) {
  usage
  exit 1
}

let action = $args[0]

if $action == "on" {
  if (path exists $swapfile) {
    echo "🔄 Enabling existing swapfile at $swapfile…"
    sudo swapon $swapfile
  } else {
    echo "⚙️  Creating 64 GiB swapfile at $swapfile…"
    sudo fallocate -l 64G $swapfile
    sudo chmod 600    $swapfile
    sudo mkswap       $swapfile
    sudo swapon       $swapfile
  }
  echo "✅ Swap is now ON."
}
elif $action == "off" {
  if (path exists $swapfile) {
    echo "🔄 Disabling swapfile at $swapfile…"
    sudo swapoff $swapfile
    echo "🗑 Removing $swapfile…"
    sudo rm $swapfile
    echo "✅ Swap is now OFF."
  } else {
    echo "⚠️  No swapfile at $swapfile to turn off."
  }
}
else {
  usage
  exit 1
}
