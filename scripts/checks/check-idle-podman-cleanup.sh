#!/usr/bin/env bash
set -euo pipefail

source_file=${1:?cleanup helper path required}
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/state/runners/forgejo-podman-runner.service"
printf '%s\n' forgejo-actions-runner.service forgejo-podman-runner.service > "$fixture/state/runner-units"
python3 - "$fixture/docker.sock" "$fixture/podman.sock" <<'PY'
import socket
import sys
for name in sys.argv[1:]:
    sock = socket.socket(socket.AF_UNIX)
    sock.bind(name)
    sock.close()
PY
cat > "$fixture/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == is-active ]]; then
  [[ ${MOCK_SERVICES_ACTIVE:-1} == 1 ]]
elif [[ $1 == show && $2 == --property=FreezerState ]]; then
  printf '%s\n' "${MOCK_FREEZER:-running}"
elif [[ $1 == show ]]; then
  printf 'ActiveState=%s\nSubState=%s\nMainPID=%s\nControlPID=0\nJob=0\n' \
    "${MOCK_RUNNER_STATE:-inactive}" "${MOCK_RUNNER_SUBSTATE:-dead}" "${MOCK_RUNNER_PID:-0}"
else
  exit 2
fi
SH
cat > "$fixture/df" <<'SH'
#!/usr/bin/env bash
printf 'Size Avail\n100 %s\n' "${MOCK_AVAILABLE:-20}"
SH
cat > "$fixture/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
[[ ${MOCK_API_FAILURE:-0} != 1 ]] || exit 7
if [[ $args == *'/containers/json?all=1'* ]]; then
  if [[ $args == *docker.sock* ]]; then
    printf '%s\n' "${MOCK_DOCKER_CONTAINERS:-[]}"
  else
    if [[ ${MOCK_RUNNING_AFTER_PRUNE:-0} == 1 && -s $MOCK_CALLS ]]; then
      printf '%s\n' '[{"State":"running"}]'
    else
      printf '%s\n' "${MOCK_PODMAN_CONTAINERS:-[]}"
    fi
  fi
elif [[ $args == *'/libpod/containers/prune'* ]]; then
  printf 'containers\n' >> "$MOCK_CALLS"
elif [[ $args == *'/libpod/images/prune?'* ]]; then
  printf 'images\n' >> "$MOCK_CALLS"
else
  exit 2
fi
SH
chmod +x "$fixture/systemctl" "$fixture/df" "$fixture/curl"
export STATE_DIR="$fixture/state" SYSTEMCTL_BIN="$fixture/systemctl"
export CURL_BIN="$fixture/curl" DF_BIN="$fixture/df" JQ_BIN=jq
export DOCKER_SOCKET="$fixture/docker.sock" PODMAN_SOCKET="$fixture/podman.sock"
export MOCK_CALLS="$fixture/calls" TRIGGER_USED_PERCENT=70
run_cleanup() { bash "$source_file"; }
expect_none() {
  : > "$MOCK_CALLS"
  run_cleanup >/dev/null 2>&1
  [[ ! -s $MOCK_CALLS ]]
}

: > "$MOCK_CALLS"
run_cleanup
[[ $(cat "$MOCK_CALLS") == $'containers\nimages' ]]
MOCK_AVAILABLE=31 expect_none
MOCK_RUNNER_STATE=activating expect_none
MOCK_RUNNER_SUBSTATE=running expect_none
MOCK_RUNNER_PID=42 expect_none
MOCK_FREEZER=frozen expect_none
MOCK_SERVICES_ACTIVE=0 expect_none
MOCK_DOCKER_CONTAINERS='[{"State":"running"}]' expect_none
MOCK_PODMAN_CONTAINERS='[{"State":"paused"}]' expect_none
MOCK_PODMAN_CONTAINERS='not-json' expect_none
MOCK_API_FAILURE=1 expect_none
: > "$MOCK_CALLS"
MOCK_RUNNING_AFTER_PRUNE=1 run_cleanup
[[ $(cat "$MOCK_CALLS") == containers ]]
for marker in owned pending teardown-required drain-pending resume-pending drain-disowned; do
  touch "$fixture/state/$marker"
  expect_none
  rm "$fixture/state/$marker"
  touch "$fixture/state/runners/forgejo-podman-runner.service/$marker"
  expect_none
  rm "$fixture/state/runners/forgejo-podman-runner.service/$marker"
done
rm "$fixture/state/runner-units"
expect_none
