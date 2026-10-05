#!/usr/bin/env bash
set -euo pipefail

source_file=${1:?cleanup helper path required}
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/state/runners/forgejo-podman-runner.service"
printf '%s\n' forgejo-actions-runner.service forgejo-podman-runner.service >"$fixture/state/runner-units"
python3 - "$fixture/docker.sock" "$fixture/podman.sock" <<'PY'
import socket
import sys
for name in sys.argv[1:]:
    sock = socket.socket(socket.AF_UNIX)
    sock.bind(name)
    sock.close()
PY
cat >"$fixture/systemctl" <<'SH'
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
cat >"$fixture/df" <<'SH'
#!/usr/bin/env bash
printf 'Size Avail\n100 %s\n' "${MOCK_AVAILABLE:-20}"
SH
cat >"$fixture/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
method=GET
previous=
for arg in "$@"; do
  [[ $previous != -X ]] || method=$arg
  previous=$arg
done
[[ ${MOCK_API_FAILURE:-0} != 1 ]] || exit 7
if [[ $method == GET && $args == *'/containers/json?all=1'* ]]; then
  if [[ $args == *docker.sock* ]]; then
    printf '%s\n' "${MOCK_DOCKER_CONTAINERS:-[]}"
  elif [[ ${MOCK_RUNNING_AFTER_PRUNE:-0} == 1 ]] && rg --quiet --line-regexp containers "$MOCK_CALLS"; then
    printf '%s\n' '[{"State":"running","Names":["/job"]}]'
  elif rg --quiet '^builder ' "$MOCK_CALLS"; then
    printf '%s\n' "${MOCK_PODMAN_AFTER_BUILDERS:-[]}"
  else
    printf '%s\n' "${MOCK_PODMAN_CONTAINERS:-[]}"
  fi
elif [[ $method == DELETE && $args == *'/libpod/containers/'* ]]; then
  [[ ${MOCK_BUILDER_DELETE_FAILURE:-0} != 1 ]] || exit 22
  name=${args##*/libpod/containers/}
  printf 'builder %s\n' "${name%%\?*}" >> "$MOCK_CALLS"
elif [[ $method == GET && $args == *'/libpod/volumes/json'* ]]; then
  printf '%s\n' "${MOCK_VOLUMES:-[]}"
elif [[ $method == DELETE && $args == *'/libpod/volumes/'* ]]; then
  status=${MOCK_VOLUME_STATUS:-204}
  [[ $status != 204 ]] || printf 'volume %s\n' "${args##*/libpod/volumes/}" >> "$MOCK_CALLS"
  printf '%s' "$status"
elif [[ $method == POST && $args == *'/libpod/containers/prune'* ]]; then
  printf 'containers\n' >> "$MOCK_CALLS"
elif [[ $method == POST && $args == *'/libpod/images/prune?filters='* ]]; then
  printf 'images\n' >> "$MOCK_CALLS"
  printf '%s\n' "${args##*filters=}" > "$MOCK_FILTERS"
else
  exit 2
fi
SH
chmod +x "$fixture/systemctl" "$fixture/df" "$fixture/curl"
export STATE_DIR="$fixture/state" SYSTEMCTL_BIN="$fixture/systemctl"
export CURL_BIN="$fixture/curl" DF_BIN="$fixture/df" JQ_BIN=jq
export DOCKER_SOCKET="$fixture/docker.sock" PODMAN_SOCKET="$fixture/podman.sock"
export MOCK_CALLS="$fixture/calls" MOCK_FILTERS="$fixture/filters" TRIGGER_USED_PERCENT=70
run_cleanup() { bash "$source_file"; }
expect_none() {
  : >"$MOCK_CALLS"
  run_cleanup >/dev/null 2>&1
  [[ ! -s $MOCK_CALLS ]]
}

: >"$MOCK_CALLS"
output=$(run_cleanup)
[[ $(cat "$MOCK_CALLS") == $'containers\nimages' ]]
[[ $(cat "$MOCK_FILTERS") == '%7B%22until%22%3A%5B%2248h%22%5D%2C%22dangling%22%3A%5B%22false%22%5D%7D' ]]
[[ $output == *'pruned builders=0 builder_volumes=0 failed_builder_volumes=0 image_min_age=48h'* ]]
: >"$MOCK_CALLS"
IMAGE_MIN_AGE=72h run_cleanup >/dev/null
[[ $(cat "$MOCK_FILTERS") == *72h* ]]
IMAGE_MIN_AGE=2d run_cleanup >/dev/null 2>&1 && exit 1
[[ $(MOCK_AVAILABLE=31 run_cleanup) == 'skipped reason=below_trigger' ]]
[[ $(MOCK_RUNNER_STATE=active run_cleanup) == 'skipped reason=runner_active unit=forgejo-actions-runner.service' ]]

# Leaked Buildx builders, running or stopped, are removed with their state
# volumes before the ordinary prune.
: >"$MOCK_CALLS"
output=$(MOCK_PODMAN_CONTAINERS='[{"State":"running","Names":["/buildx_buildkit_app0"]},{"State":"exited","Names":["/buildx_buildkit_site0"]},{"State":"exited","Names":["/job"]}]' \
  MOCK_PODMAN_AFTER_BUILDERS='[{"State":"exited","Names":["/job"]}]' \
  MOCK_VOLUMES='[{"Name":"buildx_buildkit_app0_state"},{"Name":"buildx_buildkit_gone0_state"},{"Name":"other_state"},{"Name":"buildx_buildkit_x"}]' \
  run_cleanup)
[[ $(cat "$MOCK_CALLS") == $'builder buildx_buildkit_app0\nbuilder buildx_buildkit_site0\nvolume buildx_buildkit_app0_state\nvolume buildx_buildkit_gone0_state\ncontainers\nimages' ]]
[[ $output == *'pruned builders=2 builder_volumes=2'* ]]
# A volume still in use is kept and the prune continues.
: >"$MOCK_CALLS"
output=$(MOCK_VOLUMES='[{"Name":"buildx_buildkit_app0_state"}]' MOCK_VOLUME_STATUS=409 run_cleanup)
[[ $output == *'kept_builder_volume name=buildx_buildkit_app0_state reason=in_use'* && $(cat "$MOCK_CALLS") == $'containers\nimages' ]]
# Any other volume failure is reported distinctly and fails the run after the
# prune has still run.
: >"$MOCK_CALLS"
if output=$(MOCK_VOLUMES='[{"Name":"buildx_buildkit_app0_state"}]' MOCK_VOLUME_STATUS=500 run_cleanup); then exit 1; fi
[[ $output == *'failed_builder_volume name=buildx_buildkit_app0_state status=500'* ]]
[[ $output == *'failed_builder_volumes=1'* && $(cat "$MOCK_CALLS") == $'containers\nimages' ]]
# Work under the lifecycle lock stops before a step that would outlast the
# budget runner start gates allow for.
: >"$MOCK_CALLS"
output=$(MOCK_PODMAN_CONTAINERS='[{"State":"running","Names":["/buildx_buildkit_app0"]}]' LOCK_BUDGET_SECONDS=12 run_cleanup)
[[ $output == 'skipped reason=lock_budget_exhausted step=remove_builder name=buildx_buildkit_app0' && ! -s $MOCK_CALLS ]]
output=$(LOCK_BUDGET_SECONDS=12 run_cleanup)
[[ $output == 'skipped reason=lock_budget_exhausted step=prune_images' && $(cat "$MOCK_CALLS") == containers ]]
LOCK_BUDGET_SECONDS=0 run_cleanup >/dev/null 2>&1 && exit 1
# Ending early after a failed volume removal still fails the run.
: >"$MOCK_CALLS"
if output=$(MOCK_VOLUMES='[{"Name":"buildx_buildkit_app0_state"}]' MOCK_VOLUME_STATUS=500 LOCK_BUDGET_SECONDS=12 run_cleanup); then exit 1; fi
[[ $output == *$'skipped reason=lock_budget_exhausted step=prune_images\nfailed_builder_volumes=1' ]]
# Unreadable or invalid engine responses are not reported as live containers.
[[ $(MOCK_API_FAILURE=1 run_cleanup) == 'skipped reason=engine_api_unavailable engine=docker' ]]
[[ $(MOCK_PODMAN_CONTAINERS='not-json' run_cleanup) == 'skipped reason=engine_api_invalid engine=podman' ]]
[[ $(MOCK_PODMAN_CONTAINERS='{}' run_cleanup) == 'skipped reason=engine_api_invalid engine=podman' ]]
[[ $(MOCK_PODMAN_CONTAINERS='[{"State":"running","Names":["/job"]}]' run_cleanup) == 'skipped reason=containers_live engine=podman' ]]
# Handled failures are skips, not failed steps.
[[ $(MOCK_API_FAILURE=1 run_cleanup 2>&1) != *'failed step'* ]]
[[ $(DF_BIN=false run_cleanup 2>&1) == 'skipped reason=disk_unreadable' ]]
# A failed API call names its step.
: >"$MOCK_CALLS"
if output=$(MOCK_PODMAN_CONTAINERS='[{"State":"running","Names":["/buildx_buildkit_app0"]}]' MOCK_BUILDER_DELETE_FAILURE=1 run_cleanup 2>&1 >/dev/null); then exit 1; fi
[[ $output == 'failed step=remove_builder name=buildx_buildkit_app0' ]]
# The disk trigger is checked before waiting for the lifecycle lock.
exec 8>"$fixture/state/lifecycle.lock"
flock -x 8
[[ $(MOCK_AVAILABLE=31 run_cleanup) == 'skipped reason=below_trigger' ]]
flock -u 8
exec 8>&-
# Builders never excuse another live container, and a builder that survives
# removal stops the prune.
MOCK_PODMAN_CONTAINERS='[{"State":"running","Names":["/buildx_buildkit_app0"]},{"State":"running","Names":["/job"]}]' expect_none
MOCK_PODMAN_CONTAINERS='[{"State":"running","Names":["/buildx_buildkit_app0","/job"]}]' expect_none
MOCK_PODMAN_CONTAINERS='[{"State":"running","Names":[]}]' expect_none
MOCK_PODMAN_CONTAINERS='[{"State":"running","Names":["/buildx_buildkit_bad name"]}]' expect_none
: >"$MOCK_CALLS"
MOCK_PODMAN_CONTAINERS='[{"State":"running","Names":["/buildx_buildkit_app0"]}]' \
  MOCK_PODMAN_AFTER_BUILDERS='[{"State":"running","Names":["/buildx_buildkit_app0"]}]' run_cleanup >/dev/null
[[ $(cat "$MOCK_CALLS") == 'builder buildx_buildkit_app0' ]]
MOCK_AVAILABLE=31 expect_none
MOCK_RUNNER_STATE=activating expect_none
MOCK_RUNNER_SUBSTATE=running expect_none
MOCK_RUNNER_PID=42 expect_none
MOCK_FREEZER=frozen expect_none
MOCK_SERVICES_ACTIVE=0 expect_none
MOCK_DOCKER_CONTAINERS='[{"State":"running"}]' expect_none
MOCK_PODMAN_CONTAINERS='[{"State":"paused","Names":["/job"]}]' expect_none
MOCK_DOCKER_CONTAINERS='[{"State":"running","Names":["/buildx_buildkit_app0"]}]' expect_none
MOCK_PODMAN_CONTAINERS='not-json' expect_none
MOCK_API_FAILURE=1 expect_none
: >"$MOCK_CALLS"
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
