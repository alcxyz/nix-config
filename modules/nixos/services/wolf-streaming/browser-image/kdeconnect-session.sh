#!/usr/bin/env bash
set -uo pipefail

daemon="${NIXBOX_KDECONNECT_EXECUTABLE:?missing KDE Connect executable}"
bridge="${NIXBOX_KDECONNECT_BRIDGE:-/opt/gow/kde-pointer-bridge.py}"
dbus_send="${NIXBOX_DBUS_SEND:-dbus-send}"
poll_seconds="${NIXBOX_KDECONNECT_POLL_SECONDS:-0.1}"
restart_seconds="${NIXBOX_KDECONNECT_RESTART_SECONDS:-2}"
daemon_pid=""
bridge_pid=""

stop_child() {
  local pid="${1:-}"

  [[ -n "$pid" ]] || return 0
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  stop_child "$bridge_pid"
  stop_child "$daemon_pid"
}

owner_pid() {
  "$dbus_send" \
    --session \
    --dest=org.freedesktop.DBus \
    --print-reply \
    /org/freedesktop/DBus \
    org.freedesktop.DBus.GetConnectionUnixProcessID \
    string:org.kde.kdeconnect 2>/dev/null |
    awk '$1 == "uint32" { print $2; exit }'
}

trap 'exit 0' INT TERM
trap cleanup EXIT

while true; do
  LC_ALL=C.UTF-8 \
    QT_QPA_PLATFORM=xcb \
    "$daemon" --replace &
  daemon_pid=$!

  while kill -0 "$daemon_pid" 2>/dev/null; do
    if [[ "$(owner_pid)" == "$daemon_pid" ]]; then
      break
    fi
    sleep "$poll_seconds"
  done

  if ! kill -0 "$daemon_pid" 2>/dev/null; then
    wait "$daemon_pid" 2>/dev/null || true
    daemon_pid=""
    sleep "$restart_seconds"
    continue
  fi

  while kill -0 "$daemon_pid" 2>/dev/null; do
    "$bridge" &
    bridge_pid=$!

    while kill -0 "$daemon_pid" 2>/dev/null &&
      kill -0 "$bridge_pid" 2>/dev/null; do
      sleep "$poll_seconds"
    done

    if ! kill -0 "$daemon_pid" 2>/dev/null; then
      stop_child "$bridge_pid"
      bridge_pid=""
      break
    fi

    wait "$bridge_pid" 2>/dev/null || true
    bridge_pid=""
    sleep "$restart_seconds"
  done

  wait "$daemon_pid" 2>/dev/null || true
  daemon_pid=""
  sleep "$restart_seconds"
done
