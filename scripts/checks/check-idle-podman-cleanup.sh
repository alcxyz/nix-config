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
[[ $method != GET ]] || sleep "${MOCK_GET_DELAY:-0}"
# Podman serves its native API only under a version prefix.
[[ $args != *localhost/libpod/* ]] || exit 22
podman_containers() {
  if [[ ${MOCK_RUNNING_AFTER_CONTAINERS:-0} == 1 ]] && rg --quiet '^container ' "$MOCK_CALLS"; then
    printf '%s\n' '[{"State":"running","Names":["/job"]}]'
  elif [[ -n ${MOCK_PODMAN_AFTER_BUILDERS:-} ]] && rg --quiet '^leftover ' "$MOCK_CALLS"; then
    printf '%s\n' "${MOCK_PODMAN_AFTER_BUILDERS:-[]}"
  else
    if jq -e 'type == "array"' <<< "${MOCK_PODMAN_CONTAINERS:-[]}" >/dev/null 2>&1; then
      jq -c --rawfile removed "$MOCK_CALLS" '
        ($removed | split("\n") | map(select(test("^(container|leftover) ")) | split(" ")[1])) as $ids |
        map(select(.Id as $id | $ids | index($id) == null))' <<< "${MOCK_PODMAN_CONTAINERS:-[]}"
    else
      printf '%s\n' "${MOCK_PODMAN_CONTAINERS:-[]}"
    fi
  fi
}
if [[ $method == GET && $args == *'/containers/json?all=1'* ]]; then
  if [[ $args == *docker.sock* ]]; then
    printf '%s\n' "${MOCK_DOCKER_CONTAINERS:-[]}"
  else
    podman_containers
  fi
elif [[ $method == GET && $args == *'/v5.0.0/libpod/containers/json?all=true'* ]]; then
  # The native list names pods; fixtures add Pod and IsInfra to their entries.
  if [[ -n ${MOCK_PODMAN_NATIVE:-} ]]; then
    printf '%s\n' "$MOCK_PODMAN_NATIVE"
  else
    podman_containers | jq -c 'map({Id, State, Pod: (.Pod // ""), IsInfra: (.IsInfra // false),
      Created: (.NativeCreated // "2026-01-01T00:00:00Z")})'
  fi
elif [[ $method == POST && $args == *'/containers/prune'* ]]; then
  # Bulk prune has no bounded runtime; any call is a regression.
  printf 'prune\n' >> "$MOCK_CALLS"
  exit 2
elif [[ $method == DELETE && $args == *'/v5.0.0/libpod/containers/'*'?force=true&timeout=10' ]]; then
  [[ ${MOCK_BUILDER_DELETE_FAILURE:-0} != 1 ]] || exit 22
  id=${args##*/libpod/containers/}
  printf 'leftover %s\n' "${id%%\?*}" >> "$MOCK_CALLS"
  printf '[{"Id":"%s"}]' "${id%%\?*}" > "$output"
  printf 200
elif [[ $method == DELETE && $args == *'/v5.0.0/libpod/containers/'*'?force=false' ]]; then
  id=${args##*/libpod/containers/}
  id=${id%%\?*}
  sleep "${MOCK_CONTAINER_DELAY:-0}"
  # Fail only the named container: a curl timeout, Podman's not-found or
  # internal error, or the router's plain-text 404.
  if [[ $id == "${MOCK_CONTAINER_FAILURE_ID:-}" ]]; then
    case ${MOCK_CONTAINER_STATUS:-timeout} in
      timeout) exit 28 ;;
      plain-404)
        printf '404 page not found\n' > "$output"
        printf 404
        ;;
      *)
        printf '{"cause":"no such container","message":"failed","response":%s}' "$MOCK_CONTAINER_STATUS" > "$output"
        printf '%s' "$MOCK_CONTAINER_STATUS"
        ;;
    esac
    exit 0
  fi
  printf 'container %s\n' "$id" >> "$MOCK_CALLS"
  # Pressure rising during a pass, after this removal completed.
  [[ -z ${MOCK_PRESSURE_AFTER_REMOVAL:-} ]] || printf '%s\n' "$MOCK_PRESSURE_AFTER_REMOVAL" > "$PRESSURE_FILE"
  printf '[{"Id":"%s"}]' "$id" > "$output"
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
export RUNNER_UNITS='forgejo-actions-runner.service forgejo-podman-runner.service'
export STORE_PATH="$fixture/store"
export PRESSURE_FILE="$fixture/pressure"
set_pressure() { printf 'some avg10=%s avg60=0.00 avg300=0.00 total=0\nfull avg10=%s avg60=0.00 avg300=0.00 total=0\n' "$1" "$1" >"$PRESSURE_FILE"; }
set_pressure 0.00
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
[[ $(cat "$MOCK_CALLS") == images ]]
[[ ! -e $STATE_DIR/cleanup-in-flight ]]
[[ $output == *'pruned leftovers=0 builder_volumes=0 failed_builder_volumes=0 containers=0 image_min_age=48h'* ]]
: >"$MOCK_CALLS"
IMAGE_MIN_AGE=72h run_cleanup >/dev/null
[[ ! -e $STATE_DIR/cleanup-in-flight ]]
IMAGE_MIN_AGE=2d run_cleanup >/dev/null 2>&1 && exit 1
[[ $(MOCK_AVAILABLE=31 run_cleanup) == 'skipped reason=below_trigger' ]]
[[ $(PRESSURE_ONLY=0 MOCK_AVAILABLE=31 run_cleanup) == *'pruned leftovers='* ]]
[[ $(PRESSURE_ONLY=0 MOCK_AVAILABLE=31 MOCK_RUNNER_STATE=active run_cleanup) == 'skipped reason=runner_active unit=forgejo-actions-runner.service' ]]
[[ $(PRESSURE_ONLY=0 MOCK_AVAILABLE=7 CRITICAL_FREE_PERCENT=8 run_cleanup) == 'skipped reason=below_critical_floor' ]]
PRESSURE_ONLY=invalid run_cleanup >/dev/null 2>&1 && exit 1
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
# volumes. All container kinds share one queue before volumes.
: >"$MOCK_CALLS"
output=$(MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","Created":'"$new"',"State":"running","Names":["/buildx_buildkit_app0"]},{"Id":"'"$b"'","Created":'"$new"',"State":"exited","Names":["/buildx_buildkit_site0"]},{"Id":"'"$c"'","Created":'"$old"',"State":"exited","Names":["/job"]}]' \
  MOCK_PODMAN_AFTER_BUILDERS='[{"Id":"'"$c"'","Created":'"$old"',"State":"exited","Names":["/job"]}]' \
  MOCK_VOLUMES='[{"Name":"buildx_buildkit_app0_state"},{"Name":"buildx_buildkit_gone0_state"},{"Name":"other_state"},{"Name":"buildx_buildkit_x"}]' \
  run_cleanup)
[[ $(cat "$MOCK_CALLS") == "leftover $b"$'\n'"leftover $a"$'\n'"container $c"$'\nvolume buildx_buildkit_app0_state\nvolume buildx_buildkit_gone0_state\nimages' ]]
[[ $output == *'removed_leftover kind=builder name=buildx_buildkit_app0'* && $output == *'pruned leftovers=2 builder_volumes=2 failed_builder_volumes=0 containers=1'* ]]
# A live container older than the longest job, such as a test database whose
# job was killed, is removed; a recent one or a runner job container is not.
: >"$MOCK_CALLS"
output=$(MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","Created":'"$old"',"State":"running","Names":["/docuflow-test-postgres-1-1"]},{"Id":"'"$b"'","Created":'"$old"',"State":"paused","Names":[]}]' \
  run_cleanup)
[[ $(cat "$MOCK_CALLS") == "leftover $b"$'\n'"leftover $a"$'\nimages' ]]
[[ $output == *'removed_leftover kind=stale name=docuflow-test-postgres-1-1'* && $output == *'removed_leftover kind=stale name=-'* ]]
: >"$MOCK_CALLS"
[[ $(MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","Created":'"$new"',"State":"running","Names":["/db"]}]' run_cleanup) == 'skipped reason=containers_live engine=podman' ]]
[[ $(MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","Created":'"$old"',"State":"running","Names":["/FORGEJO-ACTIONS-TASK-1_JOB-test"]}]' run_cleanup) == 'skipped reason=containers_live engine=podman' ]]
[[ $(MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","Created":"0","State":"running","Names":["/db"]}]' run_cleanup) == 'skipped reason=containers_live engine=podman' ]]
[[ $(STALE_AFTER_SECONDS=$new MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","Created":'"$old"',"State":"running","Names":["/db"]}]' run_cleanup) == 'skipped reason=containers_live engine=podman' ]]
# Leftovers on the Docker engine are not this service's to remove.
[[ $(MOCK_DOCKER_CONTAINERS='[{"Id":"'"$a"'","Created":'"$old"',"State":"running","Names":["/db"]}]' run_cleanup) == 'skipped reason=containers_live engine=docker' ]]
STALE_AFTER_SECONDS=3h run_cleanup >/dev/null 2>&1 && exit 1
# An unexpected leftover ID invalidates the snapshot before mutation.
: >"$MOCK_CALLS"
output=$(MOCK_PODMAN_CONTAINERS='[{"Id":"../x","Created":'"$old"',"State":"running","Names":["/db"]}]' run_cleanup)
[[ $output == 'skipped reason=engine_api_invalid engine=podman' && ! -s $MOCK_CALLS ]]
# Usage of the Podman store's filesystem triggers the cleanup; the guard's
# disk keeps only its critical floor.
[[ $(MOCK_DISK_AVAILABLE=20 MOCK_STORE_AVAILABLE=31 run_cleanup) == 'skipped reason=below_trigger' ]]
[[ $(MOCK_DISK_AVAILABLE=90 MOCK_STORE_AVAILABLE=20 run_cleanup) == *'pruned leftovers=0'* ]]
[[ $(CRITICAL_FREE_PERCENT=10 MOCK_DISK_AVAILABLE=5 MOCK_STORE_AVAILABLE=20 run_cleanup) == 'skipped reason=below_critical_floor' ]]
[[ $(DF_BIN="$fixture/df-store-fails" run_cleanup) == 'skipped reason=store_unreadable' ]]
# A volume still in use is kept and the cleanup continues.
: >"$MOCK_CALLS"
output=$(MOCK_VOLUMES='[{"Name":"buildx_buildkit_app0_state"}]' MOCK_VOLUME_STATUS=409 run_cleanup)
[[ $output == *'kept_builder_volume name=buildx_buildkit_app0_state reason=in_use'* && $(cat "$MOCK_CALLS") == images ]]
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
output=$(MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","Created":0,"State":"running","Names":["/buildx_buildkit_app0"]}]' LOCK_BUDGET_SECONDS=12 run_cleanup)
[[ $output == 'skipped reason=bounded_partial cause=budget step=remove_container' && ! -s $MOCK_CALLS ]]
output=$(LOCK_BUDGET_SECONDS=12 run_cleanup)
[[ $output == 'skipped reason=lock_budget_exhausted step=remove_image' && ! -s $MOCK_CALLS ]]
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
if output=$(MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","Created":0,"State":"running","Names":["/buildx_buildkit_app0"]}]' MOCK_BUILDER_DELETE_FAILURE=1 run_cleanup 2>&1 >/dev/null); then exit 1; fi
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
# removal stops the cleanup.
MOCK_PODMAN_CONTAINERS='[{"State":"running","Names":["/buildx_buildkit_app0"]},{"State":"running","Names":["/job"]}]' expect_none
MOCK_PODMAN_CONTAINERS='[{"State":"running","Names":["/buildx_buildkit_app0","/job"]}]' expect_none
MOCK_PODMAN_CONTAINERS='[{"State":"running","Names":[]}]' expect_none
MOCK_PODMAN_CONTAINERS='[{"State":"running","Names":["/buildx_buildkit_bad name"]}]' expect_none
: >"$MOCK_CALLS"
MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","Created":0,"State":"running","Names":["/buildx_buildkit_app0"]}]' \
  MOCK_PODMAN_AFTER_BUILDERS='[{"Id":"'"$a"'","Created":0,"State":"running","Names":["/buildx_buildkit_app0"]}]' run_cleanup >/dev/null
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
# A container that starts during the cleanup stops it before the images.
: >"$MOCK_CALLS"
MOCK_PODMAN_CONTAINERS='[{"Id":"'"$a"'","Created":'"$old"',"State":"exited","Names":["/job"]}]' \
  MOCK_RUNNING_AFTER_CONTAINERS=1 run_cleanup
[[ $(cat "$MOCK_CALLS") == "container $a" ]]
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
printf '%s\n' forgejo-actions-runner.service forgejo-podman-runner.service >"$fixture/state/runner-units"

# The runner list comes from the unit environment and is validated strictly
# before any lock, API request or mutation.
for units in '' forgejo-actions-runner.service \
  'forgejo-podman-runner.service forgejo-actions-runner.service' \
  'forgejo-actions-runner.service forgejo-podman-runner-fast.service forgejo-podman-runner.service' \
  'forgejo-actions-runner.service forgejo-podman-runner.service forgejo-podman-runner.service' \
  'forgejo-actions-runner.service forgejo-podman-runner.service ../escape.service' \
  'forgejo-actions-runner.service forgejo-podman-runner.service fast'; do
  : >"$MOCK_CALLS"
  : >"$MOCK_REQUESTS"
  if RUNNER_UNITS=$units run_cleanup >/dev/null 2>&1; then exit 1; fi
  [[ ! -s $MOCK_CALLS && ! -s $MOCK_REQUESTS && ! -e $STATE_DIR/cleanup-in-flight ]]
done
if (
  unset RUNNER_UNITS
  run_cleanup >/dev/null 2>&1
); then exit 1; fi

# Three runners: an extra Podman runner shares the engine, so its registry
# entry, state directory, transition markers and unit state all gate cleanup.
extra=forgejo-podman-runner-fast.service
three="forgejo-actions-runner.service forgejo-podman-runner.service $extra"
# A two-runner registry is a configuration switch awaiting reboot.
[[ $(RUNNER_UNITS=$three run_cleanup) == 'skipped reason=runner_registry_mismatch' ]]
printf '%s\n' forgejo-actions-runner.service forgejo-podman-runner.service "$extra" >"$fixture/state/runner-units"
[[ $(RUNNER_UNITS=$three run_cleanup) == 'skipped reason=runner_registry_missing' ]]
mkdir "$fixture/state/runners/$extra"
: >"$MOCK_CALLS"
RUNNER_UNITS=$three run_cleanup >/dev/null
[[ $(cat "$MOCK_CALLS") == images && ! -e $STATE_DIR/cleanup-in-flight ]]
# The two-runner configuration no longer matches the three-runner registry.
[[ $(run_cleanup) == 'skipped reason=runner_registry_mismatch' ]]
for marker in owned pending teardown-required drain-pending resume-pending drain-disowned; do
  touch "$fixture/state/runners/$extra/$marker"
  : >"$MOCK_CALLS"
  [[ $(RUNNER_UNITS=$three run_cleanup) == "skipped reason=transition_marker marker=$marker" ]]
  [[ ! -s $MOCK_CALLS ]]
  rm "$fixture/state/runners/$extra/$marker"
done
for state in active activating deactivating; do
  : >"$MOCK_CALLS"
  [[ $(RUNNER_UNITS=$three MOCK_RUNNER_UNIT=$extra MOCK_RUNNER_STATE=$state run_cleanup) == "skipped reason=runner_active unit=$extra" ]]
  [[ ! -s $MOCK_CALLS ]]
done
: >"$MOCK_CALLS"
[[ $(RUNNER_UNITS=$three MOCK_RUNNER_UNIT=$extra MOCK_RUNNER_JOB_FIELD=Job=7 run_cleanup) == "skipped reason=runner_active unit=$extra" ]]
[[ ! -s $MOCK_CALLS ]]
# An unknown runner state directory or a symlinked one is never trusted.
mkdir "$fixture/state/runners/forgejo-podman-runner-old.service"
[[ $(RUNNER_UNITS=$three run_cleanup) == 'skipped reason=runner_registry_mismatch' ]]
rmdir "$fixture/state/runners/forgejo-podman-runner-old.service"
mv "$fixture/state/runners/$extra" "$fixture/extra-state"
ln -s "$fixture/extra-state" "$fixture/state/runners/$extra"
[[ $(RUNNER_UNITS=$three run_cleanup) == 'skipped reason=runner_registry_missing' ]]
rm "$fixture/state/runners/$extra"
rmdir "$fixture/extra-state"
printf '%s\n' forgejo-actions-runner.service forgejo-podman-runner.service >"$fixture/state/runner-units"
# The leftover extra directory is unknown to the two-runner configuration.
mkdir "$fixture/state/runners/$extra"
[[ $(run_cleanup) == 'skipped reason=runner_registry_mismatch' ]]
rmdir "$fixture/state/runners/$extra"

# Exited and dead containers are removed one by one, newest first and then by
# ID, up to the limit; never by a bulk prune. Each removal is its own fenced
# request with its own deadline, so their sum may exceed one request's budget.
ids=()
for n in $(seq 1 10); do ids+=("$(printf '%064x' "$n")"); done
exited=$(for n in $(seq 1 10); do
  # IDs 1 and 2 share a creation time; dead ID 10 is the oldest.
  case $n in 1 | 2) created=5 ;; 10) created=1 ;; *) created=$((20 - n)) ;; esac
  state=exited
  [[ $n != 10 ]] || state=dead
  printf '{"Id":"%s","Created":%s,"State":"%s","Names":["/FORGEJO-ACTIONS-TASK-%s"]}\n' "${ids[n - 1]}" "$created" "$state" "$n"
done | jq -sc .)
order=(3 4 5 6 7 8 9 2 1 10)
expected=$(
  for n in "${order[@]:0:8}"; do printf 'container %s\n' "${ids[n - 1]}"; done
  printf images
)
: >"$MOCK_CALLS"
: >"$MOCK_REQUESTS"
output=$(MOCK_PODMAN_CONTAINERS=$exited run_cleanup)
[[ $(cat "$MOCK_CALLS") == "$expected" && ! -e $STATE_DIR/cleanup-in-flight ]]
[[ $output == *'pruned leftovers=0 builder_volumes=0 failed_builder_volumes=0 containers=8 image_min_age=48h images=1'* ]]
[[ $(rg --count '^removed_container id=' <<<"$output") == 8 && $output == *"removed_container id=${ids[2]}"* ]]
[[ $(rg --count --fixed-strings -- '--max-time 15 ' "$MOCK_REQUESTS") == 9 ]]
if rg --quiet --fixed-strings /containers/prune "$MOCK_REQUESTS"; then exit 1; fi
: >"$MOCK_CALLS"
output=$(CONTAINER_DELETE_LIMIT=2 MOCK_PODMAN_CONTAINERS=$exited run_cleanup)
[[ $(cat "$MOCK_CALLS") == "container ${ids[2]}"$'\n'"container ${ids[3]}"$'\nimages' ]]
[[ $output == *' containers=2 '* ]]
for limit in 0 9 x; do
  if CONTAINER_DELETE_LIMIT=$limit run_cleanup >/dev/null 2>&1; then exit 1; fi
done
# A dependent container is created after the container it depends on, so it
# goes first. Within one second the native list's fraction orders them,
# whatever their IDs.
: >"$MOCK_CALLS"
MOCK_PODMAN_CONTAINERS='[{"Id":"'"${ids[1]}"'","Created":5,"State":"exited","NativeCreated":"2026-01-01T00:00:05.1+02:00"},{"Id":"'"${ids[0]}"'","Created":5,"State":"exited","NativeCreated":"2026-01-01T00:00:05.9+02:00"}]' \
  run_cleanup >/dev/null
[[ $(cat "$MOCK_CALLS") == "container ${ids[0]}"$'\n'"container ${ids[1]}"$'\nimages' ]]
# Pod members, including infra containers, are never selected: Podman's
# prune skips them and refuses to remove an infra container on its own.
pod=$(printf 'f%.0s' {1..64})
: >"$MOCK_CALLS"
output=$(CONTAINER_DELETE_LIMIT=2 MOCK_PODMAN_CONTAINERS="$(jq -c --arg pod "$pod" '
  (.[2] |= . + {Pod: $pod, IsInfra: true}) | (.[3] |= . + {Pod: $pod})' <<<"$exited")" run_cleanup)
[[ $(cat "$MOCK_CALLS") == "container ${ids[4]}"$'\n'"container ${ids[5]}"$'\nimages' ]]
[[ $output == *' containers=2 '* && ! -e $STATE_DIR/cleanup-in-flight ]]
# The native list must be complete and valid before anything is removed.
stamp='"Created":"2026-01-01T00:00:01Z"'
for native in '{}' '[{"Id":"'"${ids[9]}"'","Pod":"","IsInfra":"false",'"$stamp"'}]' \
  '[{"Id":"'"${ids[9]}"'","Pod":"x","IsInfra":false,'"$stamp"'}]' '[{"Id":"'"${ids[9]}"'","IsInfra":false,'"$stamp"'}]' \
  '[{"Id":"'"${ids[9]}"'","Pod":"","IsInfra":false,"Created":1}]' \
  '[{"Id":"'"${ids[9]}"'","Pod":"","IsInfra":false,"Created":"yesterday"}]' \
  '[{"Id":"'"${ids[9]}"'","Pod":"","IsInfra":false,'"$stamp"'},{"Id":"'"${ids[9]}"'","Pod":"","IsInfra":false,'"$stamp"'}]' \
  '[{"Id":"'"${ids[0]}"'","Pod":"","IsInfra":false,'"$stamp"'}]'; do
  : >"$MOCK_CALLS"
  [[ $(MOCK_PODMAN_NATIVE=$native MOCK_PODMAN_CONTAINERS='[{"Id":"'"${ids[9]}"'","Created":1,"State":"exited"}]' run_cleanup) == 'skipped reason=engine_api_invalid engine=podman' ]]
  [[ ! -s $MOCK_CALLS && ! -e $STATE_DIR/cleanup-in-flight ]]
done
# Podman's JSON not-found answer is a completed refusal: the container is
# kept, the fence is cleared and the next container is removed.
: >"$MOCK_CALLS"
output=$(CONTAINER_DELETE_LIMIT=3 MOCK_CONTAINER_FAILURE_ID=${ids[3]} MOCK_CONTAINER_STATUS=404 MOCK_PODMAN_CONTAINERS=$exited run_cleanup)
[[ $(cat "$MOCK_CALLS") == "container ${ids[2]}"$'\n'"container ${ids[4]}"$'\nimages' ]]
[[ $output == *"kept_container id=${ids[3]} reason=gone"* && $output == *' containers=2 '* ]]
[[ $output != *"removed_container id=${ids[3]}"* && ! -e $STATE_DIR/cleanup-in-flight ]]
# A timed-out removal, a plain-text 404 or any other status is uncertain: the
# fence stays and no later container or image is touched.
for status in timeout plain-404 409 500; do
  : >"$MOCK_CALLS"
  if output=$(MOCK_CONTAINER_FAILURE_ID=${ids[3]} MOCK_CONTAINER_STATUS=$status MOCK_PODMAN_CONTAINERS=$exited run_cleanup 2>&1); then exit 1; fi
  case $status in
    timeout) [[ $output == *'failed step=uncertain_request kind=exited'* ]] ;;
    plain-404) [[ $output == *'failed step=invalid_response kind=exited'* ]] ;;
    *) [[ $output == *"failed step=uncertain_status kind=exited status=$status"* ]] ;;
  esac
  [[ $(cat "$MOCK_CALLS") == "container ${ids[2]}" && -d $STATE_DIR/cleanup-in-flight ]]
  [[ $(cat "$STATE_DIR/cleanup-in-flight/owner") == *" DELETE /v5.0.0/libpod/containers/${ids[3]}?force=false" ]]
  if output=$(run_cleanup 2>&1); then exit 1; fi
  [[ $output == 'failed step=cleanup_in_flight' ]]
  rm -r "$STATE_DIR/cleanup-in-flight"
done
# Each removal needs its own budget; a pass that runs out after some removals
# skips healthily and has already logged what it removed.
: >"$MOCK_CALLS"
output=$(LOCK_BUDGET_SECONDS=22 MOCK_CONTAINER_DELAY=4 CONTAINER_DELETE_LIMIT=3 MOCK_PODMAN_CONTAINERS=$exited run_cleanup)
[[ $(cat "$MOCK_CALLS") == "container ${ids[2]}"$'\n'"container ${ids[3]}" && ! -e $STATE_DIR/cleanup-in-flight ]]
[[ $output == "removed_container id=${ids[2]}"$'\n'"removed_container id=${ids[3]}"$'\nskipped reason=bounded_partial cause=budget step=remove_container' ]]
# Slow read-only requests before the loop still leave room to remove
# containers within the normal 40 s budget.
: >"$MOCK_CALLS"
: >"$MOCK_REQUESTS"
output=$(MOCK_GET_DELAY=1.1 MOCK_PODMAN_CONTAINERS=$exited run_cleanup)
# Four list requests precede the first removal.
[[ $(awk '/-X DELETE/ { exit } /-X GET/ { n++ } END { print n }' "$MOCK_REQUESTS") == 4 ]]
(($(rg --count '^removed_container id=' <<<"$output") >= 1))
[[ ! -e $STATE_DIR/cleanup-in-flight ]]
# Every exited or dead container needs a valid, unique ID and creation time
# before any of them is removed.
for invalid in '{"Id":"../x","Created":0,"State":"exited"}' '{"Created":0,"State":"dead"}' \
  '{"Id":"'"${a^^}"'","Created":0,"State":"exited"}' '{"Id":"'"$a"'","State":"exited"}' \
  '{"Id":"'"$a"'","Created":"0","State":"exited"}' '{"Id":"'"$b"'","Created":0,"State":"exited"}'; do
  : >"$MOCK_CALLS"
  [[ $(MOCK_PODMAN_CONTAINERS='[{"Id":"'"$b"'","Created":0,"State":"exited"},'"$invalid"']' run_cleanup) == 'skipped reason=engine_api_invalid engine=podman' ]]
  [[ ! -s $MOCK_CALLS && ! -e $STATE_DIR/cleanup-in-flight ]]
done

# Cleanup starts only at or below the guard's resume threshold (full avg10 in
# hundredths), before the lock and any API request, and creates no fence.
for sample in 5.01 30.25; do
  set_pressure "$sample"
  : >"$MOCK_CALLS"
  : >"$MOCK_REQUESTS"
  [[ $(run_cleanup) == "skipped reason=io_pressure full_avg10_hundredths=$(awk -v v="$sample" 'BEGIN { printf "%.0f", v * 100 }')" ]]
  [[ ! -s $MOCK_CALLS && ! -s $MOCK_REQUESTS && ! -e $STATE_DIR/cleanup-in-flight ]]
done
set_pressure 5.00
: >"$MOCK_CALLS"
[[ $(run_cleanup) == *'pruned leftovers=0'* && $(cat "$MOCK_CALLS") == images ]]
set_pressure 4.00
[[ $(IO_PRESSURE_THRESHOLD_HUNDREDTHS=300 run_cleanup) == 'skipped reason=io_pressure full_avg10_hundredths=400' ]]
for threshold in x -1 10001 ' 5'; do
  if IO_PRESSURE_THRESHOLD_HUNDREDTHS=$threshold run_cleanup >/dev/null 2>&1; then exit 1; fi
done
# The pressure skip precedes waiting for the lifecycle lock.
set_pressure 50.00
exec 8>"$fixture/state/lifecycle.lock"
flock -x 8
[[ $(run_cleanup) == 'skipped reason=io_pressure full_avg10_hundredths=5000' ]]
flock -u 8
exec 8>&-
# An unreadable or malformed sample is uncertain and never permits cleanup.
for content in missing '' 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0' 'full avg10=x avg60=0.00'; do
  rm -f "$PRESSURE_FILE"
  [[ $content == missing ]] || printf '%s\n' "$content" >"$PRESSURE_FILE"
  : >"$MOCK_REQUESTS"
  [[ $(run_cleanup) == 'skipped reason=io_pressure_unreadable' ]]
  [[ ! -s $MOCK_REQUESTS && ! -e $STATE_DIR/cleanup-in-flight ]]
done
# Pressure rising mid-pass stops it cleanly before the next mutating request:
# the completed removal cleared its own fence and no new fence is created.
for after in 'full avg10=20.00 avg60=0.00 avg300=0.00 total=0' unreadable; do
  set_pressure 0.00
  : >"$MOCK_CALLS"
  : >"$MOCK_REQUESTS"
  output=$(MOCK_PRESSURE_AFTER_REMOVAL=$after MOCK_PODMAN_CONTAINERS=$exited run_cleanup)
  expected_value=2000
  [[ $after != unreadable ]] || expected_value=unknown
  [[ $(cat "$MOCK_CALLS") == "container ${ids[2]}" && ! -e $STATE_DIR/cleanup-in-flight ]]
  [[ $output == "removed_container id=${ids[2]}"$'\n'"skipped reason=bounded_partial cause=io_pressure step=remove_container full_avg10_hundredths=$expected_value" ]]
  [[ $(rg --count -- '-X DELETE' "$MOCK_REQUESTS") == 1 ]]
done
set_pressure 0.00

# The companion uses real UNIX HTTP/curl for completion ambiguity and signals.
python3 "$(dirname "${BASH_SOURCE[0]}")/test-idle-podman-cleanup-fence.py" "$source_file"
python3 "$(dirname "${BASH_SOURCE[0]}")/test-cleanup-fence-recovery.py" "$(dirname "$source_file")"

python3 "$(dirname "${BASH_SOURCE[0]}")/test-docker-volume-cleanup.py" "$source_file"
