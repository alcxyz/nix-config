#!/usr/bin/env bash
set -euo pipefail

source_file=${1:?cleanup helper path required}
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/state/runners/forgejo-podman-runner.service"
chmod 700 "$fixture/state"
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
elif [[ $1 == show && $2 == --property=ExecMainStartTimestampMonotonic ]]; then
  printf '12345\n'
elif [[ $1 == show ]]; then
  if [[ ${*: -1} == "${MOCK_RUNNER_UNIT:-forgejo-actions-runner.service}" ]]; then
    printf 'ActiveState=%s\nSubState=%s\nMainPID=%s\nControlPID=%s\n%s\n' \
      "${MOCK_RUNNER_STATE:-inactive}" "${MOCK_RUNNER_SUBSTATE:-dead}" \
      "${MOCK_RUNNER_PID:-0}" "${MOCK_RUNNER_CONTROL_PID:-0}" "${MOCK_RUNNER_JOB_FIELD-Job=}"
  else
    printf 'ActiveState=inactive\nSubState=dead\nMainPID=0\nControlPID=0\nJob=\n'
  fi
else
  exit 2
fi
SH
cat >"$fixture/df" <<'SH'
#!/usr/bin/env bash
if [[ ${*: -1} == "$STORE_PATH" ]]; then
  available=${MOCK_STORE_AVAILABLE:-${MOCK_AVAILABLE:-20}}
else
  available=${MOCK_DISK_AVAILABLE:-${MOCK_AVAILABLE:-20}}
fi
printf 'Size Avail\n100 %s\n' "$available"
SH
cat >"$fixture/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
printf '%s\n' "$args" >> "$MOCK_REQUESTS"
method=GET
previous=
output=
for arg in "$@"; do
  [[ $previous != -X ]] || method=$arg
  [[ $previous != --output ]] || output=$arg
  previous=$arg
done
[[ ${MOCK_API_FAILURE:-0} != 1 ]] || exit 7
# Podman serves its native API only under a version prefix.
[[ $args != *localhost/libpod/* ]] || exit 22
if [[ $method == GET && $args == *'/containers/json?all=1'* ]]; then
  if [[ $args == *docker.sock* ]]; then
    printf '%s\n' "${MOCK_DOCKER_CONTAINERS:-[]}"
  elif [[ ${MOCK_RUNNING_AFTER_PRUNE:-0} == 1 ]] && rg --quiet --line-regexp containers "$MOCK_CALLS"; then
    printf '%s\n' '[{"State":"running","Names":["/job"]}]'
  elif rg --quiet '^leftover ' "$MOCK_CALLS"; then
    printf '%s\n' "${MOCK_PODMAN_AFTER_BUILDERS:-[]}"
  else
    printf '%s\n' "${MOCK_PODMAN_CONTAINERS:-[]}"
  fi
elif [[ $method == DELETE && $args == *'/v5.0.0/libpod/containers/'* ]]; then
  [[ ${MOCK_BUILDER_DELETE_FAILURE:-0} != 1 ]] || exit 22
  id=${args##*/libpod/containers/}
  printf 'leftover %s\n' "${id%%\?*}" >> "$MOCK_CALLS"
  printf '[{"Id":"%s"}]' "${id%%\?*}" > "$output"
  printf 200
elif [[ $method == GET && $args == *'/libpod/volumes/json'* ]]; then
  printf '%s\n' "${MOCK_VOLUMES:-[]}"
elif [[ $method == DELETE && $args == *'/libpod/volumes/'* ]]; then
  status=${MOCK_VOLUME_STATUS:-204}
  [[ $status != 204 ]] || printf 'volume %s\n' "${args##*/libpod/volumes/}" >> "$MOCK_CALLS"
  if [[ $status == 204 ]]; then : > "$output"; else
    printf '{"cause":"conflict","message":"in use","response":%s}' "$status" > "$output"
  fi
  printf '%s' "$status"
elif [[ $method == POST && $args == *'/libpod/containers/prune'* ]]; then
  printf 'containers\n' >> "$MOCK_CALLS"
  printf '[]' > "$output"
  printf 200
elif [[ $method == GET && $args == *'/images/json?all=true'* ]]; then
  default_images='[{"Id":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","Created":0,"Containers":0,"RepoTags":["old:tag"],"ParentId":""}]'
  printf '%s\n' "${MOCK_IMAGES:-$default_images}"
elif [[ $method == DELETE && $args == *'/images/'* ]]; then
  [[ $args == *'?force=false&noprune=true' ]]
  printf 'images\n' >> "$MOCK_CALLS"
  printf '[{"Deleted":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]' > "$output"
  printf 200
else
  exit 2
fi
SH
cat >"$fixture/df-store-fails" <<'SH'
#!/usr/bin/env bash
[[ ${*: -1} != "$STORE_PATH" ]] || exit 1
printf 'Size Avail\n100 20\n'
SH
chmod +x "$fixture/systemctl" "$fixture/df" "$fixture/curl" "$fixture/df-store-fails"
export STATE_DIR="$fixture/state" SYSTEMCTL_BIN="$fixture/systemctl"
export CURL_BIN="$fixture/curl" DF_BIN="$fixture/df" JQ_BIN=jq
export DOCKER_SOCKET="$fixture/docker.sock" PODMAN_SOCKET="$fixture/podman.sock"
export MOCK_CALLS="$fixture/calls" TRIGGER_USED_PERCENT=70
export MOCK_REQUESTS="$fixture/requests"
export STORE_PATH="$fixture/store"
a=$(printf 'a%.0s' {1..64})
b=$(printf 'b%.0s' {1..64})
c=$(printf 'c%.0s' {1..64})
# Created times: long before the stale age, and far in the future.
old=0
new=4102444800
run_cleanup() { bash "$source_file"; }
expect_none() {
  : >"$MOCK_CALLS"
  run_cleanup >/dev/null 2>&1
  [[ ! -s $MOCK_CALLS ]]
}

: >"$MOCK_CALLS"
output=$(run_cleanup)
[[ $(cat "$MOCK_CALLS") == $'containers\nimages' ]]
[[ ! -e $STATE_DIR/cleanup-in-flight ]]
[[ $output == *'pruned leftovers=0 builder_volumes=0 failed_builder_volumes=0 image_min_age=48h'* ]]
: >"$MOCK_CALLS"
IMAGE_MIN_AGE=72h run_cleanup >/dev/null
[[ ! -e $STATE_DIR/cleanup-in-flight ]]
IMAGE_MIN_AGE=2d run_cleanup >/dev/null 2>&1 && exit 1
[[ $(MOCK_AVAILABLE=31 run_cleanup) == 'skipped reason=below_trigger' ]]
[[ $(MOCK_RUNNER_STATE=active run_cleanup) == 'skipped reason=runner_active unit=forgejo-actions-runner.service' ]]

# Both runners must be fully stopped with an explicitly empty Job= field.
# Reject pending, missing and malformed fields before even reading an engine API.
expect_runner_blocked() {
  : >"$MOCK_CALLS"
  : >"$MOCK_REQUESTS"
  [[ $(run_cleanup) == "skipped reason=runner_active unit=$MOCK_RUNNER_UNIT" ]]
  [[ ! -s $MOCK_CALLS && ! -s $MOCK_REQUESTS ]]
}
for unit in forgejo-actions-runner.service forgejo-podman-runner.service; do
  for job_field in Job=123 '' Job=invalid Job=0 'Job= ' $'Job=\nJob=123'; do
    MOCK_RUNNER_UNIT=$unit MOCK_RUNNER_JOB_FIELD=$job_field expect_runner_blocked
  done
  for state in activating deactivating; do
    MOCK_RUNNER_UNIT=$unit MOCK_RUNNER_STATE=$state expect_runner_blocked
  done
  MOCK_RUNNER_UNIT=$unit MOCK_RUNNER_SUBSTATE=stop expect_runner_blocked
  MOCK_RUNNER_UNIT=$unit MOCK_RUNNER_PID=42 expect_runner_blocked
  MOCK_RUNNER_UNIT=$unit MOCK_RUNNER_CONTROL_PID=42 expect_runner_blocked
done

# Leaked Buildx builders, running or stopped, are removed with their state
# volumes before the ordinary prune.
: >"$MOCK_CALLS"
output=$(MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","Created":'"$new"',"State":"running","Names":["/buildx_buildkit_app0"]},{"Id":"'"$b"'","Created":'"$new"',"State":"exited","Names":["/buildx_buildkit_site0"]},{"Id":"'"$c"'","Created":'"$old"',"State":"exited","Names":["/job"]}]' \
  MOCK_PODMAN_AFTER_BUILDERS='[{"State":"exited","Names":["/job"]}]' \
  MOCK_VOLUMES='[{"Name":"buildx_buildkit_app0_state"},{"Name":"buildx_buildkit_gone0_state"},{"Name":"other_state"},{"Name":"buildx_buildkit_x"}]' \
  run_cleanup)
[[ $(cat "$MOCK_CALLS") == "leftover $a"$'\n'"leftover $b"$'\nvolume buildx_buildkit_app0_state\nvolume buildx_buildkit_gone0_state\ncontainers\nimages' ]]
[[ $output == *'removed_leftover kind=builder name=buildx_buildkit_app0'* && $output == *'pruned leftovers=2 builder_volumes=2'* ]]
# A live container older than the longest job, such as a test database whose
# job was killed, is removed; a recent one or a runner job container is not.
: >"$MOCK_CALLS"
output=$(MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","Created":'"$old"',"State":"running","Names":["/docuflow-test-postgres-1-1"]},{"Id":"'"$b"'","Created":'"$old"',"State":"paused","Names":[]}]' \
  run_cleanup)
[[ $(cat "$MOCK_CALLS") == "leftover $a"$'\n'"leftover $b"$'\ncontainers\nimages' ]]
[[ $output == *'removed_leftover kind=stale name=docuflow-test-postgres-1-1'* && $output == *'removed_leftover kind=stale name=-'* ]]
: >"$MOCK_CALLS"
[[ $(MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","Created":'"$new"',"State":"running","Names":["/db"]}]' run_cleanup) == 'skipped reason=containers_live engine=podman' ]]
[[ $(MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","Created":'"$old"',"State":"running","Names":["/FORGEJO-ACTIONS-TASK-1_JOB-test"]}]' run_cleanup) == 'skipped reason=containers_live engine=podman' ]]
[[ $(MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","Created":"0","State":"running","Names":["/db"]}]' run_cleanup) == 'skipped reason=containers_live engine=podman' ]]
[[ $(STALE_AFTER_SECONDS=$new MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","Created":'"$old"',"State":"running","Names":["/db"]}]' run_cleanup) == 'skipped reason=containers_live engine=podman' ]]
# Leftovers on the Docker engine are not this service's to remove.
[[ $(MOCK_DOCKER_CONTAINERS='[{"Id":"'"$a"'","Created":'"$old"',"State":"running","Names":["/db"]}]' run_cleanup) == 'skipped reason=containers_live engine=docker' ]]
STALE_AFTER_SECONDS=3h run_cleanup >/dev/null 2>&1 && exit 1
# A leftover with an unexpected ID fails instead of being removed by name.
: >"$MOCK_CALLS"
if output=$(MOCK_PODMAN_CONTAINERS='[{"Id":"../x","Created":'"$old"',"State":"running","Names":["/db"]}]' run_cleanup 2>&1 >/dev/null); then exit 1; fi
[[ $output == 'failed step=remove_leftover id=invalid' && ! -s $MOCK_CALLS ]]
# Usage of the Podman store's filesystem triggers the cleanup; the guard's
# disk keeps only its critical floor.
[[ $(MOCK_DISK_AVAILABLE=20 MOCK_STORE_AVAILABLE=31 run_cleanup) == 'skipped reason=below_trigger' ]]
[[ $(MOCK_DISK_AVAILABLE=90 MOCK_STORE_AVAILABLE=20 run_cleanup) == *'pruned leftovers=0'* ]]
[[ $(CRITICAL_FREE_PERCENT=10 MOCK_DISK_AVAILABLE=5 MOCK_STORE_AVAILABLE=20 run_cleanup) == 'skipped reason=below_critical_floor' ]]
[[ $(DF_BIN="$fixture/df-store-fails" run_cleanup) == 'skipped reason=store_unreadable' ]]
# A volume still in use is kept and the prune continues.
: >"$MOCK_CALLS"
output=$(MOCK_VOLUMES='[{"Name":"buildx_buildkit_app0_state"}]' MOCK_VOLUME_STATUS=409 run_cleanup)
[[ $output == *'kept_builder_volume name=buildx_buildkit_app0_state reason=in_use'* && $(cat "$MOCK_CALLS") == $'containers\nimages' ]]
# An unexpected volume failure is uncertain; no later destructive request runs.
: >"$MOCK_CALLS"
if output=$(MOCK_VOLUMES='[{"Name":"buildx_buildkit_app0_state"}]' MOCK_VOLUME_STATUS=500 run_cleanup 2>&1); then exit 1; fi
[[ $output == *'uncertain_status kind=volume status=500'* ]]
[[ -d $STATE_DIR/cleanup-in-flight && ! -s $MOCK_CALLS ]]
if output=$(run_cleanup 2>&1); then exit 1; fi
[[ $output == 'failed step=cleanup_in_flight' ]]
rm -r "$STATE_DIR/cleanup-in-flight"
# Work under the lifecycle lock stops before a step that would outlast the
# budget runner start gates allow for.
: >"$MOCK_CALLS"
output=$(MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","State":"running","Names":["/buildx_buildkit_app0"]}]' LOCK_BUDGET_SECONDS=12 run_cleanup)
[[ $output == 'skipped reason=lock_budget_exhausted step=remove_leftover name=buildx_buildkit_app0' && ! -s $MOCK_CALLS ]]
output=$(LOCK_BUDGET_SECONDS=12 run_cleanup)
[[ $output == 'skipped reason=lock_budget_exhausted step=remove_image' && $(cat "$MOCK_CALLS") == containers ]]
LOCK_BUDGET_SECONDS=0 run_cleanup >/dev/null 2>&1 && exit 1
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
if output=$(MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","State":"running","Names":["/buildx_buildkit_app0"]}]' MOCK_BUILDER_DELETE_FAILURE=1 run_cleanup 2>&1 >/dev/null); then exit 1; fi
[[ $output == 'failed step=uncertain_request kind=container' ]]
[[ -d $STATE_DIR/cleanup-in-flight ]]
rm -r "$STATE_DIR/cleanup-in-flight"
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
MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","State":"running","Names":["/buildx_buildkit_app0"]}]' \
  MOCK_PODMAN_AFTER_BUILDERS='[{"Id":"'"$a"'","State":"running","Names":["/buildx_buildkit_app0"]}]' run_cleanup >/dev/null
[[ $(cat "$MOCK_CALLS") == "leftover $a" ]]
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

# The companion uses real UNIX HTTP/curl for completion ambiguity and signals.
python3 "$(dirname "${BASH_SOURCE[0]}")/test-idle-podman-cleanup-fence.py" "$source_file"
python3 "$(dirname "${BASH_SOURCE[0]}")/test-cleanup-fence-recovery.py" "$(dirname "$source_file")"
