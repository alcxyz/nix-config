#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SOURCE="$ROOT/users/alc/linux/xyz/desktop-helpers.nix"
TMP=$(mktemp -d)

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  printf 'game window geometry guard: FAIL: %s\n' "$*" >&2
  exit 1
}

extract_function() {
  local name=$1

  awk -v start="      $name() {" '
    $0 == start { copying = 1 }
    copying {
      sub(/^      /, "")
      print
    }
    copying && $0 == "}" { exit }
  ' "$SOURCE" | sed "s/''\${/\${/g"
}

extract_function repair_geometry >"$TMP/repair-geometry.sh"
extract_function watch_geometry_events >"$TMP/watch-geometry-events.sh"
# shellcheck disable=SC2016 # Match the literal production variable reference.
sed -i 's/: >"$repair_requested"/arm_repair/' "$TMP/watch-geometry-events.sh"

[[ -s "$TMP/repair-geometry.sh" ]] || fail 'could not extract repair_geometry'
[[ -s "$TMP/watch-geometry-events.sh" ]] || fail 'could not extract watch_geometry_events'

# The policy and client names are intentionally synthetic. The geometry mirrors
# the stacked-output failure that this guard is meant to contain.
# shellcheck disable=SC2034 # Used by the sourced production function.
policies='[{"classRegex":"^Regression Game$","titleRegex":"^Test Window$","initialClassRegex":null,"initialTitleRegex":null,"restoreMonitor":"DP-1","snapFullHeight":true,"workspace":8,"centerOnRecovery":true}]'
# shellcheck disable=SC2034 # Used by the sourced production function.
tolerance=16
# shellcheck disable=SC2034 # Used by the sourced production function.
provider=legacy
monitors_json='[{"id":1,"name":"DP-1","x":0,"y":1456,"width":5120,"height":1440,"dpmsStatus":true},{"id":2,"name":"DP-2","x":0,"y":0,"width":2560,"height":1440,"dpmsStatus":true}]'
clients_json='[]'
dispatch_log="$TMP/dispatch.log"

hyprctl() {
  case "$1 ${2:-}" in
    'monitors -j') printf '%s\n' "$monitors_json" ;;
    'clients -j') printf '%s\n' "$clients_json" ;;
    'dispatch movewindowpixel')
      printf '%s\n' "$3" >>"$dispatch_log"
      printf 'ok\n'
      ;;
    'eval '*)
      printf '%s\n' "$2" >>"$dispatch_log"
      printf 'ok\n'
      ;;
    *) fail "unexpected hyprctl call: $*" ;;
  esac
}

# shellcheck source=/dev/null
source "$TMP/repair-geometry.sh"

client() {
  local x=$1 y=$2 workspace=$3 floating=$4 fullscreen=$5 monitor=${6:-1}

  jq -cn \
    --argjson x "$x" --argjson y "$y" --argjson workspace "$workspace" \
    --argjson floating "$floating" --argjson fullscreen "$fullscreen" \
    --argjson monitor "$monitor" \
    '[{
      address: "0xabc", class: "Regression Game", title: "Test Window",
      initialClass: "", initialTitle: "", monitor: $monitor,
      workspace: {id: $workspace}, mapped: true, hidden: false,
      floating: $floating, fullscreen: $fullscreen,
      at: [$x, $y], size: [3440, 1440]
    }]'
}

assert_move() {
  local description=$1 expected=$2
  shift 2
  : >"$dispatch_log"
  clients_json=$(client "$@")
  repair_geometry >/dev/null
  [[ "$(<"$dispatch_log")" == "$expected" ]] ||
    fail "$description: expected '$expected', got '$(<"$dispatch_log")'"
}

assert_no_move() {
  local description=$1
  shift
  : >"$dispatch_log"
  clients_json=$(client "$@")
  repair_geometry >/dev/null
  [[ ! -s "$dispatch_log" ]] ||
    fail "$description unexpectedly dispatched '$(<"$dispatch_log")'"
}

assert_move 'stale stacked-output geometry' \
  'exact 840 1456,address:0xabc' 1678 1454 8 true 0
assert_no_move 'already centered geometry' 840 1456 8 true 0

provider=lua
assert_move 'stale geometry with Lua configuration provider' \
  'hl.dispatch(hl.dsp.window.move({ x = 840, y = 1456, window = "address:0xabc" }))' \
  1678 1454 8 true 0
# shellcheck disable=SC2034 # Used by the sourced production function.
provider=legacy

assert_no_move 'another workspace' 1678 1454 4 true 0
assert_no_move 'tiled window' 1678 1454 8 false 0
assert_no_move 'fullscreen window' 1678 1454 8 true 1

monitors_json=$(jq 'map(if .name == "DP-1" then .dpmsStatus = false else . end)' <<<"$monitors_json")
assert_no_move 'output with DPMS disabled' 1678 1454 8 true 0
monitors_json=$(jq 'map(if .name == "DP-1" then .dpmsStatus = true else . end)' <<<"$monitors_json")
assert_no_move 'workspace on another output' 1678 1454 8 true 0 2

# Exercise event identification separately. A matching window may arm the guard
# once, repeated title events must not re-arm it, and closing it resets its
# lifetime so a later open can arm the guard again.
mkdir "$TMP/bin"
cat >"$TMP/bin/socat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

count=0
[[ ! -f "$GUARD_TEST_SOCAT_COUNT" ]] || count=$(<"$GUARD_TEST_SOCAT_COUNT")
count=$((count + 1))
printf '%s\n' "$count" >"$GUARD_TEST_SOCAT_COUNT"
if ((count == 1)); then
  printf '%s\n' \
    'openwindow>>111,8,Regression Game,Unrelated' \
    'windowtitlev2>>222,Test Window' \
    'windowtitlev2>>222,Test Window' \
    'closewindow>>222' \
    'openwindow>>222,8,Regression Game,Test Window'
else
  sleep 1
fi
EOF
chmod +x "$TMP/bin/socat"
sed -i "1s|.*|#!$(command -v bash)|" "$TMP/bin/socat"

repair_requested="$TMP/repair-requested"
# shellcheck disable=SC2034 # Used by the sourced production function.
socket="$TMP/mock.sock"
clients_json=$(client 840 1456 8 true 0 | jq '.[0].address = "0x222"')
export GUARD_TEST_SOCAT_COUNT="$TMP/socat-count"
export -f hyprctl fail

# shellcheck source=/dev/null
source "$TMP/watch-geometry-events.sh"

arm_log="$TMP/arm.log"
: >"$arm_log"
arm_repair() {
  printf 'arm\n' >>"$arm_log"
  : >"$repair_requested"
}

PATH="$TMP/bin:$PATH" watch_geometry_events &
watcher_pid=$!

deadline=$((SECONDS + 3))
while ((SECONDS < deadline)); do
  [[ $(wc -l <"$arm_log" 2>/dev/null || true) -ge 2 ]] && break
  sleep 0.02
done
kill "$watcher_pid" 2>/dev/null || true
wait "$watcher_pid" 2>/dev/null || true

arm_count=$(wc -l <"$arm_log" 2>/dev/null || true)
[[ "$arm_count" == 2 ]] ||
  fail "event watcher armed $arm_count times; expected once per matching window lifetime"

printf 'game window geometry guard: PASS\n'
