#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SOURCE="$ROOT/users/alc/linux/xyz/desktop-scripts/game-window-geometry-guard.sh"
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

  awk -v start="$name() {" '
    $0 == start { copying = 1 }
    copying {
      print
    }
    copying && $0 == "}" { exit }
  ' "$SOURCE"
}

extract_function repair_geometry >"$TMP/repair-geometry.sh"
extract_function watch_geometry_events >"$TMP/watch-geometry-events.sh"
extract_function update_recovery_deadlines >"$TMP/update-recovery-deadlines.sh"
# shellcheck disable=SC2016 # Match the literal production variable reference.
sed -i 's/printf .%s.n. "$address" >>"$repair_requested"/arm_repair "$address"/' "$TMP/watch-geometry-events.sh"
# shellcheck disable=SC2016 # Match the literal hooked call.
grep -q 'arm_repair "$address"' "$TMP/watch-geometry-events.sh" ||
  fail 'could not hook the watcher arm request'

[[ -s "$TMP/repair-geometry.sh" ]] || fail 'could not extract repair_geometry'
[[ -s "$TMP/watch-geometry-events.sh" ]] || fail 'could not extract watch_geometry_events'
[[ -s "$TMP/update-recovery-deadlines.sh" ]] || fail 'could not extract update_recovery_deadlines'

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
monitor_query_succeeds=true

hyprctl() {
  case "$1 ${2:-}" in
    'monitors -j')
      [[ "$monitor_query_succeeds" == true ]] || return 1
      printf '%s\n' "$monitors_json"
      ;;
    'clients -j')
      if [[ -n "${GUARD_TEST_CLIENTS_DIR:-}" ]]; then
        # Replay numbered snapshots, repeating the last one.
        local count=0
        [[ ! -f "$GUARD_TEST_CLIENTS_DIR/count" ]] || count=$(<"$GUARD_TEST_CLIENTS_DIR/count")
        count=$((count + 1))
        printf '%s\n' "$count" >"$GUARD_TEST_CLIENTS_DIR/count"
        [[ -f "$GUARD_TEST_CLIENTS_DIR/clients-$count" ]] || count=$((count - 1))
        cat "$GUARD_TEST_CLIENTS_DIR/clients-$count"
      else
        printf '%s\n' "$clients_json"
      fi
      ;;
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

# Display recovery preserves intentional horizontal placement. It only repairs
# the small vertical drift seen after DPMS, and leaves contained placement alone.
: >"$dispatch_log"
clients_json=$(client 1678 1454 8 true 0)
repair_geometry display >/dev/null
[[ "$(<"$dispatch_log")" == 'exact 1678 1456,address:0xabc' ]] ||
  fail "display recovery did not preserve horizontal placement: '$(<"$dispatch_log")'"

: >"$dispatch_log"
clients_json=$(client 1200 1456 8 true 0)
repair_geometry display >/dev/null
[[ ! -s "$dispatch_log" ]] ||
  fail "display recovery moved fully contained placement: '$(<"$dispatch_log")'"

# Launch recovery retains the lifecycle contract and centers the same placement.
assert_move 'launch recovery centers contained off-center placement' \
  'exact 840 1456,address:0xabc' 1200 1456 8 true 0

# A home offset replaces centering with a declared placement relative to the
# restore monitor. Either recovery mode returns a window there only when it is
# outside the output, so contained windows sharing its identity stay put.
game_policies=$policies
policies='[{"classRegex":"^Regression Game$","titleRegex":"^Test Window$","restoreMonitor":"DP-1","workspace":8,"homeOffset":{"x":16,"y":16}}]'
home_client() {
  client "$@" | jq -c '.[0].size = [160, 20]'
}
assert_home() {
  local description=$1 mode=$2 expected=$3
  shift 3
  : >"$dispatch_log"
  clients_json=$(home_client "$@")
  repair_geometry "$mode" >/dev/null
  [[ "$(<"$dispatch_log")" == "$expected" ]] ||
    fail "$description: expected '$expected', got '$(<"$dispatch_log")'"
}
assert_home 'launch recovery places an off-screen window at home' launch \
  'exact 16 1472,address:0xabc' 15 12 8 true 0
assert_home 'launch recovery leaves contained placement alone' launch '' \
  400 1600 8 true 0
assert_home 'launch recovery leaves a window at home' launch '' 16 1472 8 true 0
assert_home 'display recovery returns an off-screen window home' display \
  'exact 16 1472,address:0xabc' 15 12 8 true 0
assert_home 'display recovery leaves contained placement alone' display '' \
  400 1600 8 true 0

# The production policy order: game first, then the launcher, then the tray.
# Launch recovery scoped to one address must leave every other watched
# window alone, so opening one window cannot undo another's placement.
policies='[
  {"classRegex":"^Regression Game$","titleRegex":"^Test Window$","restoreMonitor":"DP-1","snapFullHeight":true,"workspace":8,"centerOnRecovery":true},
  {"classRegex":"^Regression Game$","titleRegex":"^Launcher$","restoreMonitor":"DP-1","workspace":8,"centerOnRecovery":true},
  {"classRegex":"^Regression Game$","titleRegex":"^$","restoreMonitor":"DP-1","workspace":8,"homeOffset":{"x":16,"y":16}}
]'
watched_client() {
  jq -cn --arg address "$1" --arg title "$2" --argjson x "$3" --argjson y "$4" \
    --argjson width "$5" --argjson height "$6" '{
      address: $address, class: "Regression Game", title: $title,
      initialClass: "", initialTitle: "", monitor: 1, workspace: {id: 8},
      mapped: true, hidden: false, floating: true, fullscreen: 0,
      at: [$x, $y], size: [$width, $height]
    }'
}
clients_json=$(jq -cs '.' \
  <(watched_client 0xgame 'Test Window' 1678 1454 3440 1440) \
  <(watched_client 0xlauncher Launcher 400 1500 1600 1376) \
  <(watched_client 0xtray '' 15 12 160 20))
: >"$dispatch_log"
repair_geometry launch $'0xgame\n' >/dev/null
[[ "$(<"$dispatch_log")" == 'exact 840 1456,address:0xgame' ]] ||
  fail "scoped launch recovery touched other windows: '$(<"$dispatch_log")'"
: >"$dispatch_log"
repair_geometry launch '*' >/dev/null
[[ "$(<"$dispatch_log")" == $'exact 840 1456,address:0xgame\nexact 1760 1488,address:0xlauncher\nexact 16 1472,address:0xtray' ]] ||
  fail "unscoped launch recovery did not apply each policy: '$(<"$dispatch_log")'"
clients_json=$(jq -cs '.' \
  <(watched_client 0xgame 'Test Window' 840 1456 3440 1440) \
  <(watched_client 0xlauncher Launcher 400 1500 1600 1376) \
  <(watched_client 0xtray '' 15 12 160 20))
: >"$dispatch_log"
repair_geometry display >/dev/null
[[ "$(<"$dispatch_log")" == 'exact 16 1472,address:0xtray' ]] ||
  fail "display recovery did not return only the uncontained window: '$(<"$dispatch_log")'"
policies=$game_policies

# Exercise deadline updates without relying on wall-clock sleeps. A transition
# from no watched output to an available one must arm recovery even when no
# compositor event was emitted and considerable time has passed.
# shellcheck disable=SC2034 # Used by the sourced production function.
display_requested="$TMP/display-requested"
# shellcheck disable=SC2034 # Used by the sourced production function.
repair_requested="$TMP/repair-requested"
# shellcheck disable=SC2034 # Used by the sourced production functions.
request_lock="$TMP/repair-requested.lock"
# shellcheck source=/dev/null
source "$TMP/update-recovery-deadlines.sh"

display_until=0
launch_until=0
launch_scope=''
last_display_signature=''
monitors_on=$monitors_json
monitors_json=$(jq 'map(if .name == "DP-1" then .dpmsStatus = false else . end)' <<<"$monitors_on")
SECONDS=5
update_recovery_deadlines >/dev/null
[[ "$display_until" == 0 && "$last_display_signature" == '[]' ]] ||
  fail 'absent watched monitor armed display recovery'

monitors_json=$monitors_on
SECONDS=500
update_recovery_deadlines >/dev/null
[[ "$display_until" == 590 ]] ||
  fail "off-to-on transition without event armed until $display_until; expected 590"

SECONDS=510
update_recovery_deadlines >/dev/null
[[ "$display_until" == 590 ]] ||
  fail "unchanged available monitor extended deadline to $display_until"

monitor_query_succeeds=false
last_signature=$last_display_signature
display_until=0
SECONDS=600
update_recovery_deadlines >/dev/null
[[ "$display_until" == 0 && "$last_display_signature" == "$last_signature" ]] ||
  fail 'failed monitor query fabricated a wake or replaced the last known state'
monitor_query_succeeds=true

# Requests are read under the watcher's lock. An empty request arms
# nothing: startup arms its own sweep.
display_until=700
launch_until=0
launch_scope=''
: >"$repair_requested"
SECONDS=650
update_recovery_deadlines >/dev/null
[[ "$launch_until" == 0 && "$launch_scope" == '' && ! -e "$repair_requested" ]] ||
  fail "empty request armed launch recovery: '$launch_scope' until $launch_until"

printf '0xone\n' >"$repair_requested"
SECONDS=652
update_recovery_deadlines >/dev/null
[[ "$launch_until" == 662 && "$launch_scope" == $'0xone\n' ]] ||
  fail "launch request armed '$launch_scope' until $launch_until; expected 0xone until 662"
[[ "$display_until" == 700 ]] ||
  fail "launch request shortened display deadline to $display_until"

# A reader waits for an append that holds the lock, rather than missing it.
# shellcheck disable=SC2016 # Expanded by the child shell.
flock "$request_lock" bash -c ': >"$2"; sleep 0.4; printf "0xheld\n" >>"$1"' \
  _ "$repair_requested" "$TMP/lock-held" &
holder_pid=$!
deadline=$((SECONDS + 5))
until [[ -e "$TMP/lock-held" ]]; do
  ((SECONDS < deadline)) || fail 'lock holder did not start'
  sleep 0.02
done
update_recovery_deadlines >/dev/null
wait "$holder_pid"
[[ "$launch_scope" == $'0xone\n0xheld\n' ]] ||
  fail "request was not read after the lock was released: '$launch_scope'"
launch_scope=$'0xone\n'

# Address requests accumulate within one launch window and start afresh after it.
printf '0xtwo\n' >"$repair_requested"
SECONDS=655
update_recovery_deadlines >/dev/null
[[ "$launch_scope" == $'0xone\n0xtwo\n' && "$launch_until" == 665 ]] ||
  fail "launch requests did not accumulate: '$launch_scope' until $launch_until"
printf '0xthree\n' >"$repair_requested"
SECONDS=700
update_recovery_deadlines >/dev/null
[[ "$launch_scope" == $'0xthree\n' ]] ||
  fail "expired launch window kept its old scope: '$launch_scope'"

# A wildcard sweep stays a wildcard when requests arrive during it.
launch_scope='*'
printf '0xfour\n' >"$repair_requested"
SECONDS=705
update_recovery_deadlines >/dev/null
[[ "$launch_scope" == '*' ]] ||
  fail "request narrowed a wildcard sweep to '$launch_scope'"

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

# A window that maps untitled matches the tray policy first. When its real
# title selects another policy, the watcher must arm recovery again, but a
# repeated title, or a title flipping back to a policy it already matched,
# must not.
policies='[
  {"classRegex":"^Regression Game$","titleRegex":"^Test Window$"},
  {"classRegex":"^Regression Game$","titleRegex":"^$"}
]'
mkdir "$TMP/snapshots"
watched_client 0x333 '' 15 12 160 20 | jq -cs '.' >"$TMP/snapshots/clients-1"
watched_client 0x333 'Test Window' 15 12 3440 1440 | jq -cs '.' >"$TMP/snapshots/clients-2"
cp "$TMP/snapshots/clients-2" "$TMP/snapshots/clients-3"
cp "$TMP/snapshots/clients-1" "$TMP/snapshots/clients-4"
cp "$TMP/snapshots/clients-2" "$TMP/snapshots/clients-5"
export GUARD_TEST_CLIENTS_DIR="$TMP/snapshots"
cat >"$TMP/bin/socat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f "$GUARD_TEST_SOCAT_COUNT.retitle" ]]; then
  : >"$GUARD_TEST_SOCAT_COUNT.retitle"
  printf '%s\n' \
    'openwindow>>333,8,Regression Game,' \
    'windowtitlev2>>333,Test Window' \
    'windowtitlev2>>333,Test Window' \
    'windowtitlev2>>333,' \
    'windowtitlev2>>333,Test Window'
else
  sleep 1
fi
EOF
sed -i "1s|.*|#!$(command -v bash)|" "$TMP/bin/socat"
: >"$arm_log"
PATH="$TMP/bin:$PATH" watch_geometry_events &
watcher_pid=$!
deadline=$((SECONDS + 3))
while ((SECONDS < deadline)); do
  [[ $(wc -l <"$arm_log" 2>/dev/null || true) -ge 2 ]] && break
  sleep 0.02
done
sleep 0.2
kill "$watcher_pid" 2>/dev/null || true
wait "$watcher_pid" 2>/dev/null || true
arm_count=$(wc -l <"$arm_log" 2>/dev/null || true)
[[ "$arm_count" == 2 ]] ||
  fail "retitled window armed $arm_count times; expected once per matching policy"

printf 'game window geometry guard: PASS\n'
