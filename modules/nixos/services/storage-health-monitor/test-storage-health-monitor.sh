#!/usr/bin/env bash
set -euo pipefail

if (($# != 3)); then
  echo 'usage: test-storage-health-monitor RECORD_SUCCESS CHECK_RECENT_SUCCESS CHECK_ACTIVE_UNIT' >&2
  exit 2
fi

record_success=$1
check_recent_success=$2
check_active_unit=$3
sandbox=$(mktemp -d)
trap 'rm -rf -- "$sandbox"' EXIT
state=$sandbox/state
marker=$state/unit
mkdir -m 0700 "$state"

run_recorder() {
  SERVICE_RESULT=$1 EXIT_CODE=$2 EXIT_STATUS=$3 \
    "$BASH" "$record_success" "$marker"
}

SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0 \
  "$BASH" "$record_success" "$marker"
[[ $(<"$marker") =~ ^[0-9]+$ ]]
[[ $(stat -c %a "$marker") == 600 ]]
printf '100\n' >"$marker"
touch -d '@100' "$marker"
for result in failure timeout success exit-code; do
  case $result in
    failure) tuple=(exit-code exited 1) ;;
    timeout) tuple=(timeout killed TERM) ;;
    success) tuple=(success killed TERM) ;;
    exit-code) tuple=(exit-code exited 0) ;;
  esac
  run_recorder "${tuple[@]}"
  [[ $(<"$marker") == 100 ]]
  [[ $(stat -c %Y "$marker") == 100 ]]
done

mkdir "$sandbox/bin"
printf '#!%s\n' "$BASH" >"$sandbox/bin/date"
cat >>"$sandbox/bin/date" <<'EOF'
if [[ ${FIXTURE_DATE_MODE:-failure} == signal ]]; then
  kill -TERM "$PPID"
  sleep 1
fi
if [[ ${FIXTURE_DATE_MODE:-failure} == malformed ]]; then
  printf 'not-a-timestamp\n'
  exit 0
fi
exit 42
EOF
chmod +x "$sandbox/bin/date"
if PATH="$sandbox/bin:$PATH" SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0 \
  "$BASH" "$record_success" "$marker"; then
  echo 'recorder accepted a failed timestamp write' >&2
  exit 1
else
  recorder_status=$?
fi
[[ $recorder_status -eq 42 ]]
[[ $(<"$marker") == 100 ]]
[[ $(stat -c %Y "$marker") == 100 ]]
if PATH="$sandbox/bin:$PATH" FIXTURE_DATE_MODE=malformed \
  SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0 \
  "$BASH" "$record_success" "$marker"; then
  echo 'recorder accepted a malformed timestamp' >&2
  exit 1
fi
[[ $(<"$marker") == 100 ]]
[[ $(stat -c %Y "$marker") == 100 ]]
if PATH="$sandbox/bin:$PATH" FIXTURE_DATE_MODE=signal \
  SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0 \
  "$BASH" "$record_success" "$marker"; then
  echo 'recorder continued after a termination signal' >&2
  exit 1
else
  recorder_status=$?
fi
[[ $recorder_status -eq 143 ]]
[[ $(<"$marker") == 100 ]]
[[ $(stat -c %Y "$marker") == 100 ]]
if compgen -G "$state/.success.*" >/dev/null; then
  echo 'recorder left temporary state after interruption' >&2
  exit 1
fi

printf '#!%s\n' "$BASH" >"$sandbox/systemctl"
cat >>"$sandbox/systemctl" <<'EOF'
set -euo pipefail
if [[ ${FIXTURE_SYSTEMCTL_FAIL:-false} == true ]]; then
  exit 96
fi
if [[ $1 == is-active ]]; then
  printf '%s\n' "${FIXTURE_ACTIVE_STATE:-active}"
elif [[ $1 == show ]]; then
  property=$4
  if [[ $property == LastTriggerUSec &&
    ${FIXTURE_LAST_TRIGGER_FAIL:-false} == true ]]; then
    exit 95
  fi
  case $property in
    Result) printf '%s\n' "${FIXTURE_RESULT:-}" ;;
    ExecMainCode) printf '%s\n' "${FIXTURE_CODE:-}" ;;
    ExecMainStatus) printf '%s\n' "${FIXTURE_STATUS:-}" ;;
    InactiveEnterTimestampMonotonic) printf '%s\n' "${FIXTURE_FINISHED:-0}" ;;
    LastTriggerUSec) printf '%s\n' "${FIXTURE_LAST_TRIGGER:-}" ;;
    ActiveState) printf '%s\n' "${FIXTURE_TIMER_STATE:-inactive}" ;;
    StatusText) printf '%s\n' "${FIXTURE_STATUS_TEXT-monitoring}" ;;
    *) exit 97 ;;
  esac
else
  exit 97
fi
EOF
printf '#!%s\n' "$BASH" >"$sandbox/date"
cat >>"$sandbox/date" <<'EOF'
set -euo pipefail
[[ $1 == +%s ]]
printf '%s\n' "${FIXTURE_NOW:?}"
EOF
chmod +x "$sandbox/systemctl" "$sandbox/date"
printf '200.00 0.00\n' >"$sandbox/uptime"

STORAGE_HEALTH_SYSTEMCTL=$sandbox/systemctl \
  "$BASH" "$check_active_unit" fixture.service active
STORAGE_HEALTH_SYSTEMCTL=$sandbox/systemctl \
  "$BASH" "$check_active_unit" fixture.service active-not-degraded
if output=$(FIXTURE_ACTIVE_STATE=inactive STORAGE_HEALTH_SYSTEMCTL=$sandbox/systemctl \
  "$BASH" "$check_active_unit" fixture.service active-not-degraded); then
  echo 'inactive service passed active health check' >&2
  exit 1
fi
grep -Fqx 'fixture.service: required service is not active' <<<"$output"
if output=$(FIXTURE_STATUS_TEXT='degraded: operator recovery required' \
  STORAGE_HEALTH_SYSTEMCTL=$sandbox/systemctl \
  "$BASH" "$check_active_unit" fixture.service active-not-degraded); then
  echo 'degraded service passed status health check' >&2
  exit 1
fi
grep -Fqx 'fixture.service: degraded: operator recovery required' <<<"$output"
if output=$(FIXTURE_STATUS_TEXT='' STORAGE_HEALTH_SYSTEMCTL=$sandbox/systemctl \
  "$BASH" "$check_active_unit" fixture.service active-not-degraded); then
  echo 'empty service status passed status health check' >&2
  exit 1
fi
grep -Fqx 'fixture.service: service status is empty or malformed' <<<"$output"
if output=$(FIXTURE_STATUS_TEXT=$'monitoring\nunexpected' \
  STORAGE_HEALTH_SYSTEMCTL=$sandbox/systemctl \
  "$BASH" "$check_active_unit" fixture.service active-not-degraded); then
  echo 'multi-line service status passed status health check' >&2
  exit 1
fi
grep -Fqx 'fixture.service: service status is empty or malformed' <<<"$output"
FIXTURE_STATUS_TEXT='degraded: informational only' \
  STORAGE_HEALTH_SYSTEMCTL=$sandbox/systemctl \
  "$BASH" "$check_active_unit" fixture.service active

check_fixture() {
  FIXTURE_RESULT=${FIXTURE_RESULT:-success} \
    FIXTURE_CODE=${FIXTURE_CODE:-0} \
    FIXTURE_STATUS=${FIXTURE_STATUS:-0} \
    FIXTURE_FINISHED=${FIXTURE_FINISHED:-0} \
    FIXTURE_LAST_TRIGGER=${FIXTURE_LAST_TRIGGER:-} \
    FIXTURE_LAST_TRIGGER_FAIL=${FIXTURE_LAST_TRIGGER_FAIL:-false} \
    FIXTURE_TIMER_STATE=${FIXTURE_TIMER_STATE:-inactive} \
    FIXTURE_SYSTEMCTL_FAIL=${FIXTURE_SYSTEMCTL_FAIL:-false} \
    FIXTURE_NOW=${FIXTURE_NOW:-0} \
    STORAGE_HEALTH_SYSTEMCTL=$sandbox/systemctl \
    STORAGE_HEALTH_DATE=$sandbox/date \
    "$BASH" "$check_recent_success" \
    fixture.service 50 "$1" "$marker" "$sandbox/uptime"
}

printf '175\n' >"$marker"
# A new boot has no monotonic completion state, so the durable marker is enough.
FIXTURE_NOW=200 check_fixture false
if output=$(FIXTURE_SYSTEMCTL_FAIL=true FIXTURE_NOW=200 check_fixture false); then
  echo 'durable success passed without current unit state' >&2
  exit 1
fi
grep -Fq 'current unit state is unavailable' <<<"$output"
printf '100\n' >"$marker"
if output=$(FIXTURE_NOW=200 check_fixture false); then
  echo 'stale durable success passed' >&2
  exit 1
fi
grep -Fqx 'fixture.service: last successful completion is 100 seconds old' <<<"$output"

printf 'invalid\n' >"$marker"
if output=$(FIXTURE_NOW=200 check_fixture false); then
  echo 'malformed durable success passed' >&2
  exit 1
fi
grep -Fq 'timestamp is malformed' <<<"$output"
printf '175\nextra\n' >"$marker"
if output=$(FIXTURE_NOW=200 check_fixture false); then
  echo 'multi-line durable success passed' >&2
  exit 1
fi
grep -Fq 'timestamp is malformed' <<<"$output"
printf '9999999999999999999\n' >"$marker"
if output=$(FIXTURE_NOW=200 check_fixture false); then
  echo 'overflowing durable success passed' >&2
  exit 1
fi
grep -Fq 'timestamp is malformed' <<<"$output"
printf '201\n' >"$marker"
if output=$(FIXTURE_NOW=200 check_fixture false); then
  echo 'future durable success passed' >&2
  exit 1
fi
grep -Fq 'timestamp is in the future' <<<"$output"

printf '175\n' >"$marker"
if output=$(FIXTURE_RESULT=timeout FIXTURE_CODE=2 FIXTURE_STATUS=15 \
  FIXTURE_NOW=200 check_fixture false); then
  echo 'current failure did not override durable success' >&2
  exit 1
fi
grep -Fq 'last result is timeout with code 2 and status 15' <<<"$output"
if output=$(FIXTURE_RESULT=exit-code FIXTURE_CODE=1 FIXTURE_STATUS=0 \
  FIXTURE_NOW=200 check_fixture false); then
  echo 'failed post-start did not override durable success' >&2
  exit 1
fi
grep -Fq 'last result is exit-code with code 1 and status 0' <<<"$output"

rm "$marker"
FIXTURE_RESULT=success FIXTURE_CODE=1 FIXTURE_STATUS=0 \
  FIXTURE_FINISHED=175000000 check_fixture false
if output=$(FIXTURE_RESULT=success FIXTURE_CODE=1 FIXTURE_STATUS=0 \
  FIXTURE_FINISHED=100000000 check_fixture false); then
  echo 'stale current-boot fallback passed' >&2
  exit 1
fi
grep -Fqx 'fixture.service: last successful completion is 100 seconds old' <<<"$output"

FIXTURE_TIMER_STATE=active FIXTURE_LAST_TRIGGER='' check_fixture true
if output=$(FIXTURE_LAST_TRIGGER_FAIL=true FIXTURE_TIMER_STATE=active \
  check_fixture true); then
  echo 'pending first timer passed without trigger metadata' >&2
  exit 1
fi
grep -Fqx 'fixture.service: first-timer state is unavailable' <<<"$output"
if output=$(FIXTURE_TIMER_STATE=inactive FIXTURE_LAST_TRIGGER='' \
  check_fixture true); then
  echo 'missing success passed with an inactive first timer' >&2
  exit 1
fi
grep -Fqx 'fixture.service: no successful completion timestamp' <<<"$output"
if output=$(FIXTURE_TIMER_STATE=active FIXTURE_LAST_TRIGGER='today' \
  check_fixture true); then
  echo 'missing success passed after the first timer trigger' >&2
  exit 1
fi
grep -Fqx 'fixture.service: no successful completion timestamp' <<<"$output"
if output=$(check_fixture false); then
  echo 'missing regular success passed' >&2
  exit 1
fi
grep -Fqx 'fixture.service: no successful completion timestamp' <<<"$output"

echo 'storage health durable success tests: PASS'
