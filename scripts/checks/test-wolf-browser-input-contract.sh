#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BROWSER_IMAGE="$ROOT/modules/nixos/services/wolf-streaming/browser-image"
SESSION="$BROWSER_IMAGE/kdeconnect-session.sh"
DESKTOP_SESSION="$BROWSER_IMAGE/desktop-session.sh"
POINTER_BRIDGE="$BROWSER_IMAGE/kde-pointer-bridge.py"
WOLF_MODULE="$ROOT/modules/nixos/services/wolf-streaming/default.nix"
TMP=$(mktemp -d)
SUPERVISOR_PID=""

fail() {
  printf 'wolf browser input contract: FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$SUPERVISOR_PID" ]] && kill -0 "$SUPERVISOR_PID" 2>/dev/null; then
    kill "$SUPERVISOR_PID" 2>/dev/null || true
    wait "$SUPERVISOR_PID" 2>/dev/null || true
  fi

  if [[ -f "$TMP/events" ]]; then
    while read -r _event pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      kill "$pid" 2>/dev/null || true
    done <"$TMP/events"
  fi

  rm -rf "$TMP"
}

trap cleanup EXIT

wait_for_count() {
  local pattern=$1
  local expected=$2
  local deadline=$((SECONDS + 5))
  local count

  while ((SECONDS < deadline)); do
    count=$(grep -c -F "$pattern" "$TMP/events" 2>/dev/null || true)
    if ((count >= expected)); then
      return 0
    fi
    sleep 0.02
  done

  fail "timed out waiting for event '$pattern' (wanted $expected, saw ${count:-0})"
}

line_number() {
  local pattern=$1
  local occurrence=$2

  grep -n -F "$pattern" "$TMP/events" |
    sed -n "${occurrence}s/:.*//p"
}

# Movement is mirrored from the X pointer. Buttons remain on KDE Connect's
# native XTest path; intercepting them caused the click regression.
grep -Fq 'XQueryPointer' "$POINTER_BRIDGE" ||
  fail 'pointer movement is no longer read from XQueryPointer'
grep -Fq 'seat seat0 cursor set' "$POINTER_BRIDGE" ||
  fail 'pointer movement is no longer mirrored to the nested Sway seat'
if grep -Fq 'test-xi2' "$POINTER_BRIDGE"; then
  fail 'XI2 source filtering reintroduced the lost-movement regression'
fi
if grep -R -E -q 'LD_PRELOAD|libkdeconnect-scroll-throttle' \
  "$DESKTOP_SESSION" "$SESSION" "$BROWSER_IMAGE/Dockerfile" \
  "$BROWSER_IMAGE/Dockerfile.nix" "$WOLF_MODULE"; then
  fail 'KDE Connect button interception was reintroduced'
fi

# One supervisor must own the daemon and bridge so the bridge cannot bind to a
# stale D-Bus owner or survive a daemon restart.
grep -Fq '/opt/gow/kdeconnect-session.sh &' "$DESKTOP_SESSION" ||
  fail 'desktop session does not launch the input supervisor'
grep -Fq 'GetConnectionUnixProcessID' "$SESSION" ||
  fail 'input supervisor does not verify the KDE Connect D-Bus owner PID'
for dockerfile in "$BROWSER_IMAGE/Dockerfile" "$BROWSER_IMAGE/Dockerfile.nix"; do
  grep -Fq 'COPY --chmod=0755 kdeconnect-session.sh /opt/gow/kdeconnect-session.sh' "$dockerfile" ||
    fail "$(basename "$dockerfile") does not install the input supervisor"
done

cat >"$TMP/fake-daemon" <<'EOF'
#!/usr/bin/env bash
set -u

stop() {
  printf 'daemon-stop %s\n' "$$" >>"$INPUT_TEST_EVENTS"
  rm -f "$INPUT_TEST_READY"
  exit 0
}

trap stop INT TERM
printf 'daemon-start %s\n' "$$" >>"$INPUT_TEST_EVENTS"
sleep 0.15
printf '%s\n' "$$" >"$INPUT_TEST_READY"
printf 'daemon-ready %s\n' "$$" >>"$INPUT_TEST_EVENTS"
while true; do
  sleep 0.1
done
EOF

cat >"$TMP/fake-dbus-send" <<'EOF'
#!/usr/bin/env bash
set -u

if [[ -s "$INPUT_TEST_READY" ]]; then
  printf '   uint32 %s\n' "$(<"$INPUT_TEST_READY")"
fi
EOF

cat >"$TMP/fake-bridge" <<'EOF'
#!/usr/bin/env bash
set -u

stop() {
  printf 'bridge-stop %s\n' "$$" >>"$INPUT_TEST_EVENTS"
  exit 0
}

trap stop INT TERM
printf 'bridge-start %s\n' "$$" >>"$INPUT_TEST_EVENTS"
while true; do
  sleep 0.1
done
EOF

chmod +x "$TMP/fake-daemon" "$TMP/fake-dbus-send" "$TMP/fake-bridge"
for fixture in "$TMP/fake-daemon" "$TMP/fake-dbus-send" "$TMP/fake-bridge"; do
  sed -i "1s|.*|#!$(command -v bash)|" "$fixture"
done
: >"$TMP/events"

INPUT_TEST_EVENTS="$TMP/events" \
  INPUT_TEST_READY="$TMP/ready" \
  NIXBOX_KDECONNECT_EXECUTABLE="$TMP/fake-daemon" \
  NIXBOX_KDECONNECT_BRIDGE="$TMP/fake-bridge" \
  NIXBOX_DBUS_SEND="$TMP/fake-dbus-send" \
  NIXBOX_KDECONNECT_POLL_SECONDS=0.02 \
  NIXBOX_KDECONNECT_RESTART_SECONDS=0.02 \
  bash "$SESSION" &
SUPERVISOR_PID=$!

wait_for_count 'daemon-ready ' 1
wait_for_count 'bridge-start ' 1

first_start=$(line_number 'daemon-start ' 1)
first_ready=$(line_number 'daemon-ready ' 1)
first_bridge=$(line_number 'bridge-start ' 1)
((first_start < first_ready && first_ready < first_bridge)) ||
  fail 'bridge started before the daemon became the verified D-Bus owner'

first_daemon_pid=$(awk '$1 == "daemon-start" { print $2; exit }' "$TMP/events")
kill "$first_daemon_pid"

wait_for_count 'bridge-stop ' 1
wait_for_count 'daemon-start ' 2
wait_for_count 'daemon-ready ' 2
wait_for_count 'bridge-start ' 2

first_bridge_stop=$(line_number 'bridge-stop ' 1)
second_daemon_start=$(line_number 'daemon-start ' 2)
second_daemon_ready=$(line_number 'daemon-ready ' 2)
second_bridge_start=$(line_number 'bridge-start ' 2)
((first_bridge_stop < second_daemon_start && \
second_daemon_start < second_daemon_ready && \
second_daemon_ready < second_bridge_start)) ||
  fail 'daemon restart did not replace the bridge in the required order'

kill "$SUPERVISOR_PID"
wait "$SUPERVISOR_PID"
SUPERVISOR_PID=""

wait_for_count 'bridge-stop ' 2
wait_for_count 'daemon-stop ' 2

printf 'wolf browser input contract: PASS\n'
