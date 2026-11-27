# Keep one dynamic netconsole target pointed at a receiver on the local link.
#
# Arguments: target name, interface, local IPv4 address, receiver IPv4
# address, receiver UDP port, seconds between checks.
#
# The target is (re)configured through configfs only once the interface holds
# the local address and the receiver's MAC address is in the neighbour table,
# so a slow NIC or an absent receiver at boot delays the target instead of
# losing it. Every check also repairs a target the kernel disabled (for
# example after the interface was unregistered) and follows a changed
# receiver MAC address. Nothing here removes the target.
name="$1"
interface="$2"
local_address="$3"
remote_address="$4"
remote_port="$5"
interval="$6"

root=/sys/kernel/config/netconsole
target="$root/$name"

neighbour_mac() {
  local fields=()
  read -r -a fields < <(ip -4 neigh show to "$remote_address" dev "$interface" 2>/dev/null) || true
  for i in "${!fields[@]}"; do
    if [[ ${fields[i]} == lladdr ]]; then
      printf '%s\n' "${fields[i + 1]}"
      return
    fi
  done
}

has_local_address() {
  [[ $(ip -4 -o addr show dev "$interface" 2>/dev/null) == *" $local_address/"* ]]
}

# Any packet to the receiver makes the kernel resolve its MAC address; a
# datagram to the netconsole port needs no capability and reaches only the
# receiver, which logs it.
probe() {
  printf 'netconsole-target: resolving the receiver on %s\n' "$interface" \
    2>/dev/null >"/dev/udp/$remote_address/$remote_port" || true
}

current() {
  cat "$target/$1" 2>/dev/null || true
}

# Write one configfs attribute. A failed write (for example to an attribute
# the kernel holds while the target is enabled) is logged and returned, so it
# never ends the loop and never touches a target that already works.
set_attribute() {
  if ! echo "$2" 2>/dev/null >"$target/$1"; then
    echo "netconsole target $name: writing $1 failed" >&2
    return 1
  fi
}

configure() {
  local mac="$1"
  if [[ -d $target ]]; then
    if [[ $(current enabled) == 1 ]]; then
      set_attribute enabled 0 || return 1
    fi
  elif ! mkdir "$target" 2>/dev/null; then
    echo "netconsole target $name: creating $target failed" >&2
    return 1
  fi
  set_attribute dev_name "$interface" || return 1
  set_attribute local_ip "$local_address" || return 1
  set_attribute remote_ip "$remote_address" || return 1
  set_attribute remote_port "$remote_port" || return 1
  set_attribute remote_mac "$mac" || return 1
  set_attribute enabled 1 || return 1
  echo "netconsole target $name: $interface $local_address -> $remote_address:$remote_port ($mac)"
}

# The target outlives this service (see the module), so a restart after a
# configuration change must also compare the addresses and the port.
up_to_date() {
  [[ $(current enabled) == 1 &&
    $(current dev_name) == "$interface" &&
    $(current local_ip) == "$local_address" &&
    $(current remote_ip) == "$remote_address" &&
    $(current remote_port) == "$remote_port" &&
    $(current remote_mac) == "$1" ]]
}

if [[ ! -d $root ]]; then
  echo "$root is missing: is the netconsole module loaded?" >&2
  exit 1
fi

while :; do
  if has_local_address; then
    mac=$(neighbour_mac)
    if [[ -z $mac ]]; then
      probe
      sleep 1
      mac=$(neighbour_mac)
    fi
    if [[ -z $mac ]]; then
      echo "netconsole target $name: no MAC address for $remote_address yet" >&2
    elif ! up_to_date "$mac"; then
      configure "$mac" || echo "netconsole target $name: retrying in ${interval}s" >&2
    fi
  fi
  sleep "$interval"
done
