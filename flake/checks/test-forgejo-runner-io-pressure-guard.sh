#!/usr/bin/env bash
set -euo pipefail

guard=${1:?usage: test-forgejo-runner-io-pressure-guard GUARD}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat >"$work/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
command=$1
shift
case $command in
  ps)
    [[ ${PS_FAIL:-0} != 1 ]] || exit 1
    printf 'docker-ps %s\n' "$*" >>"$CALL_LOG"
    if [[ " $* " == *" --all "* ]]; then
      id_filter=${*: -1}
      id=${id_filter#id=}
      [[ -e $CONTAINER_STATE/$id ]] && printf '%s\n' "$id"
      exit 0
    fi
    [[ " $* " == *" --filter label=io.alc.forgejo-runner=test "* ]] || exit 3
    status=
    [[ " $* " == *" --filter status=running "* ]] && status=running
    [[ " $* " == *" --filter status=paused "* ]] && status=paused
    [[ -n $status ]] || exit 3
    for state_file in "$CONTAINER_STATE"/*; do
      [[ -e $state_file ]] || continue
      id=$(basename "$state_file")
      [[ $(cat "$state_file") == "$status" ]] && printf '%s\n' "$id"
    done
    exit 0
    ;;
  pause)
    for id in "$@"; do
      printf 'pause %s\n' "$id" >>"$CALL_LOG"
      [[ $id != ${PAUSE_FAIL_ID:-} ]] || exit 1
      printf paused >"$CONTAINER_STATE/$id"
    done
    ;;
  unpause)
    count=0
    for id in "$@"; do
      count=$((count + 1))
      printf 'unpause %s\n' "$id" >>"$CALL_LOG"
      printf running >"$CONTAINER_STATE/$id"
      if [[ ${UNPAUSE_FAIL_AFTER:-0} -eq $count ]]; then exit 1; fi
    done
    ;;
  inspect)
    id=${*: -1}
    [[ $id != ${INSPECT_FAIL_ID:-} ]] || exit 1
    [[ -e $CONTAINER_STATE/$id ]] || exit 1
    if [[ $id == ${INSPECT_FAIL_RUNNING_ID:-} && $(cat "$CONTAINER_STATE/$id") == running ]]; then
      exit 1
    fi
    [[ $(cat "$CONTAINER_STATE/$id") == paused ]] && printf 'true\n' || printf 'false\n'
    ;;
  *) exit 2 ;;
esac
SH

cat >"$work/bin/logger" <<'SH'
#!/usr/bin/env bash
printf 'logger %s\n' "$*" >>"$CALL_LOG"
SH
cat >"$work/bin/systemd-notify" <<'SH'
#!/usr/bin/env bash
printf 'notify %s\n' "$*" >>"$CALL_LOG"
if [[ " $* " == *" --ready "* && -n ${INJECT_UNCERTAIN_ID:-} ]]; then
  : >"$STATE_DIR/uncertain/$INJECT_UNCERTAIN_ID"
fi
SH
sed -i "1c #!$(command -v bash)" "$work/bin/docker" "$work/bin/logger" "$work/bin/systemd-notify"
chmod +x "$work/bin/"*

run_guard() {
  local state=$1 values=$2 iterations=$3
  shift 3
  : >"$work/calls"
  CONTAINER_STATE="$state/containers" \
    CALL_LOG="$work/calls" \
    STATE_DIR="$state/guard" \
    PRESSURE_VALUES_FILE="$values" \
    RUNNER_CONTAINER_LABEL=io.alc.forgejo-runner=test \
    HIGH_SAMPLES_REQUIRED=2 \
    LOW_SAMPLES_REQUIRED=3 \
    SAMPLE_SECONDS=0 \
    DOCKER_TIMEOUT_SECONDS=1 \
    DOCKER_BIN="$work/bin/docker" \
    LOGGER_BIN="$work/bin/logger" \
    SYSTEMD_NOTIFY_BIN="$work/bin/systemd-notify" \
    MAX_ITERATIONS="$iterations" \
    PATH="$work/bin:$PATH" \
    "$@" "$guard"
}

new_state() {
  mkdir -p "$1/containers"
}

# Sustained high pressure pauses every owned running component. One quiet
# window resumes the complete owned batch while a foreign pause is untouched.
state=$work/hysteresis
new_state "$state"
printf running >"$state/containers/aaaaaaaaaaaa"
printf running >"$state/containers/abababababab"
printf running >"$state/containers/acacacacacac"
printf paused >"$state/containers/bbbbbbbbbbbb"
printf '%s\n' 25 25 25 4 4 4 >"$state/pressure"
run_guard "$state" "$state/pressure" 6 env
for id in aaaaaaaaaaaa abababababab acacacacacac; do
  grep -Fxq "pause $id" "$work/calls"
  grep -Fxq "unpause $id" "$work/calls"
  [[ $(cat "$state/containers/$id") == running ]]
done
if rg -q 'bbbbbbbbbbbb' "$work/calls"; then
  echo "guard touched a container outside its exact runner label" >&2
  exit 1
fi
[[ ! -e $state/guard/guarded ]]

# A crash after pause but before ownership commit leaves pending intent. Restart
# converts it to uncertain ownership and never resumes or reports recovery.
state=$work/pause-crash
new_state "$state"
printf running >"$state/containers/cccccccccccc"
printf '%s\n' 25 25 25 >"$state/high"
if run_guard "$state" "$state/high" 3 env TEST_EXIT_AFTER_PAUSE=1; then
  echo "pause crash injection unexpectedly succeeded" >&2
  exit 1
fi
if [[ ! -e $state/guard/pending/cccccccccccc ]]; then
  ls -laR "$state/guard" >&2
  cat "$work/calls" >&2
  exit 1
fi
printf '%s\n' 4 4 4 4 >"$state/low"
run_guard "$state" "$state/low" 4 env
[[ -e $state/guard/uncertain/cccccccccccc ]]
[[ -e $state/guard/guarded ]]
[[ $(cat "$state/containers/cccccccccccc") == paused ]]
if rg -q '^unpause cccccccccccc$' "$work/calls"; then
  echo "guard resumed a pause with ambiguous ownership" >&2
  exit 1
fi
grep -q 'operator recovery is required' "$work/calls"

# A crash after batch unpause makes all old ownership ambiguous. Restart does
# not unpause again, even if an operator paused one of those containers.
state=$work/resume-crash
new_state "$state"
for id in aaaaaaaaaaaa abababababab; do printf paused >"$state/containers/$id"; done
mkdir -p "$state/guard/paused"
: >"$state/guard/paused/aaaaaaaaaaaa"
: >"$state/guard/paused/abababababab"
: >"$state/guard/guarded"
printf '%s\n' 4 4 4 4 >"$state/low-one"
if run_guard "$state" "$state/low-one" 4 env TEST_EXIT_AFTER_UNPAUSE=1; then
  echo "resume crash injection unexpectedly succeeded" >&2
  exit 1
fi
[[ -e $state/guard/resume-intent ]]
printf paused >"$state/containers/aaaaaaaaaaaa"
printf '%s\n' 4 >"$state/restart"
run_guard "$state" "$state/restart" 1 env
[[ -e $state/guard/uncertain/aaaaaaaaaaaa ]]
[[ -e $state/guard/uncertain/abababababab ]]
[[ $(cat "$state/containers/aaaaaaaaaaaa") == paused ]]
if rg -q '^unpause ' "$work/calls"; then
  echo "guard repeated an ambiguous batch resume" >&2
  exit 1
fi

# Partial batch failure is rolled back and remains guarded and owned.
state=$work/partial
new_state "$state"
for id in aaaaaaaaaaaa abababababab; do printf paused >"$state/containers/$id"; done
mkdir -p "$state/guard/paused"
: >"$state/guard/paused/aaaaaaaaaaaa"
: >"$state/guard/paused/abababababab"
: >"$state/guard/guarded"
printf '%s\n' 4 4 4 4 >"$state/low"
run_guard "$state" "$state/low" 4 env UNPAUSE_FAIL_AFTER=1
[[ $(cat "$state/containers/aaaaaaaaaaaa") == paused ]]
[[ $(cat "$state/containers/abababababab") == paused ]]
[[ -e $state/guard/paused/aaaaaaaaaaaa ]]
[[ -e $state/guard/paused/abababababab ]]
[[ -e $state/guard/guarded ]]
grep -Fq 'pause aaaaaaaaaaaa' "$work/calls"
grep -q 'restoring pauses' "$work/calls"

# If rollback cannot verify a partially resumed batch, ownership becomes
# uncertain and no later automatic resume is allowed.
state=$work/partial-ambiguous
new_state "$state"
for id in aaaaaaaaaaaa abababababab; do printf paused >"$state/containers/$id"; done
mkdir -p "$state/guard/paused"
: >"$state/guard/paused/aaaaaaaaaaaa"
: >"$state/guard/paused/abababababab"
: >"$state/guard/guarded"
printf '%s\n' 4 4 4 4 >"$state/low"
run_guard "$state" "$state/low" 4 env UNPAUSE_FAIL_AFTER=1 INSPECT_FAIL_RUNNING_ID=aaaaaaaaaaaa
[[ -e $state/guard/uncertain/aaaaaaaaaaaa ]]
[[ -e $state/guard/uncertain/abababababab ]]
[[ -e $state/guard/guarded ]]
[[ ! -e $state/guard/resume-intent ]]
grep -q 'ambiguous ownership' "$work/calls"

# Inspect errors retain ownership and degraded state.
state=$work/inspect-error
new_state "$state"
printf paused >"$state/containers/dddddddddddd"
mkdir -p "$state/guard/paused"
: >"$state/guard/paused/dddddddddddd"
: >"$state/guard/guarded"
printf '%s\n' 4 4 4 4 >"$state/low"
run_guard "$state" "$state/low" 4 env INSPECT_FAIL_ID=dddddddddddd
[[ -e $state/guard/paused/dddddddddddd ]]
[[ -e $state/guard/guarded ]]
grep -q 'could not inspect an owned paused container' "$work/calls"

# A failed pause never creates ownership, but retains pending intent until its
# outcome can be positively reconciled. Docker reporting the container as
# running after restart does not prove that the failed pause had no effect, so
# the guard preserves the attempt as uncertain instead of retrying it.
state=$work/pause-failure
new_state "$state"
printf running >"$state/containers/eeeeeeeeeeee"
printf '%s\n' 25 25 25 >"$state/high"
run_guard "$state" "$state/high" 3 env PAUSE_FAIL_ID=eeeeeeeeeeee
[[ ! -e $state/guard/paused/eeeeeeeeeeee ]]
[[ -e $state/guard/pending/eeeeeeeeeeee ]]
[[ $(cat "$state/containers/eeeeeeeeeeee") == running ]]
printf '%s\n' 4 >"$state/low"
run_guard "$state" "$state/low" 1 env
[[ ! -e $state/guard/pending/eeeeeeeeeeee ]]
[[ -e $state/guard/uncertain/eeeeeeeeeeee ]]
[[ -e $state/guard/guarded ]]
[[ $(cat "$state/containers/eeeeeeeeeeee") == running ]]
if rg -q '^pause eeeeeeeeeeee$|^unpause eeeeeeeeeeee$' "$work/calls"; then
  echo "guard mutated a container after a failed pause became ambiguous" >&2
  exit 1
fi
grep -q 'failed pause has ambiguous ownership' "$work/calls"

# Runtime malformed PSI fails closed by entering guarded state and pausing work.
state=$work/malformed-runtime
new_state "$state"
printf running >"$state/containers/ffffffffffff"
printf '%s\n' 10 malformed >"$state/pressure"
run_guard "$state" "$state/pressure" 2 env
[[ -e $state/guard/guarded ]]
[[ -e $state/guard/paused/ffffffffffff ]]
[[ $(cat "$state/containers/ffffffffffff") == paused ]]

# Startup cannot report ready without valid PSI and a working Docker probe.
state=$work/malformed-startup
new_state "$state"
printf '%s\n' malformed >"$state/pressure"
if run_guard "$state" "$state/pressure" 1 env; then
  echo "malformed startup PSI unexpectedly became ready" >&2
  exit 1
fi
grep -q 'unreadable or malformed at startup' "$work/calls"

state=$work/docker-failure
new_state "$state"
printf '%s\n' 10 >"$state/pressure"
if run_guard "$state" "$state/pressure" 1 env PS_FAIL=1; then
  echo "Docker API failure unexpectedly became ready" >&2
  exit 1
fi
grep -q 'Docker API unavailable at startup' "$work/calls"

# The guard never becomes ready or mutates containers without durable state.
state=$work/state-init-failure
new_state "$state"
touch "$state/guard"
printf '%s\n' 10 >"$state/pressure"
if run_guard "$state" "$state/pressure" 1 env; then
  echo "state initialization failure unexpectedly became ready" >&2
  exit 1
fi
grep -q 'ownership state directory could not be initialized' "$work/calls"

state=$work/guarded-write-failure
new_state "$state"
printf running >"$state/containers/121212121212"
mkdir -p "$state/guard/guarded"
printf '%s\n' 25 25 25 >"$state/pressure"
if run_guard "$state" "$state/pressure" 3 env; then
  echo "guarded-state write failure unexpectedly continued" >&2
  exit 1
fi
[[ $(cat "$state/containers/121212121212") == running ]]
grep -Eq 'guard state could not be persisted|guard state is not a regular file' "$work/calls"

# Recovery state introduced after startup must replace the normal status even
# when pressure stays low. It never authorizes resuming the ambiguous pause.
state=$work/runtime-recovery-state
new_state "$state"
printf paused >"$state/containers/343434343434"
printf '%s\n' 4 4 >"$state/pressure"
run_guard "$state" "$state/pressure" 2 env INJECT_UNCERTAIN_ID=343434343434
[[ -e $state/guard/guarded ]]
[[ -e $state/guard/uncertain/343434343434 ]]
[[ $(cat "$state/containers/343434343434") == paused ]]
grep -q 'notify --status=degraded: runner pause ownership requires recovery' "$work/calls"
if rg -q '^unpause ' "$work/calls"; then
  echo "guard resumed a runtime pause with ambiguous ownership" >&2
  exit 1
fi
