#!/usr/bin/env bash
# Exercises recheck.sh against a stand-in systemctl: the boot check reruns
# only when the ignored units differ from the recorded list, or when the unit
# arrives on a running host whose check has not passed.
set -euo pipefail

if (($# != 1)); then
  echo 'usage: test-recheck RECHECK' >&2
  exit 2
fi

recheck=$1
sandbox=$(mktemp -d)
trap 'rm -rf -- "$sandbox"' EXIT
mkdir "$sandbox/bin" "$sandbox/result" "$sandbox/record"
calls=$sandbox/calls
record=$sandbox/record/ignored-units

# The build sandbox has no /usr/bin/env, so the stand-in names this bash.
printf '#!%s\n' "$BASH" >"$sandbox/bin/systemctl"
cat >>"$sandbox/bin/systemctl" <<'EOF'
printf '%s\n' "$*" >>"$SYSTEMCTL_CALLS"
if [[ $1 == show ]]; then
  printf '%s\n' "$BOOT_CHECK_STATE"
fi
EOF
chmod +x "$sandbox/bin/systemctl"

run() {
  : >"$calls"
  PATH="$sandbox/bin:$PATH" SYSTEMCTL_CALLS=$calls BOOT_CHECK_STATE=$1 \
    NIXFLEET_BOOT_CHECK_RESULT_DIR=$sandbox/result \
    NIXFLEET_BOOT_CHECK_RECHECK_RECORD=$record \
    NIXFLEET_BOOT_CHECK_IGNORED_UNITS=$2 \
    "$BASH" "$recheck" >/dev/null
}

restarted() {
  grep -qx 'restart --no-block nixfleet-boot-check.service' "$calls"
}

# set -e ignores a negated command, so the negation lives in a function.
not_restarted() {
  ! restarted
}

# The stand-in reports its first argument as the boot check's SubState:
# exited (finished, kept active), running, failed or dead.

# Early in a boot the check has not run: record the list, never restart.
run dead "a.service"
not_restarted
[[ $(<"$record") == "ignored=a.service" ]]

# The check ran; an unchanged list (a package update restarting this unit)
# leaves it alone.
printf 'status=failed\n' >"$sandbox/result/result"
run failed "a.service"
not_restarted
[[ ! -s $calls ]]

# A changed list reruns the check once, and only once.
run failed "a.service b.service"
restarted
[[ $(<"$record") == "ignored=a.service b.service" ]]
run exited "a.service b.service"
not_restarted

# Emptying the list is a change too.
run exited ""
restarted
[[ $(<"$record") == "ignored=" ]]

# Added to a running host: a finished check that passed is only recorded.
printf 'status=ok\ntime=1\n' >"$sandbox/result/result"
rm "$record"
run exited "a.service"
not_restarted
[[ $(<"$record") == "ignored=a.service" ]]

# Added while the check still runs with the old list: restart it.
printf 'status=running\ntime=1\n' >"$sandbox/result/result"
rm "$record"
run running "a.service"
restarted
[[ $(<"$record") == "ignored=a.service" ]]

# A rerun that has just started still shows the last result, ok: it is
# running all the same, so restart it.
printf 'status=ok\ntime=1\n' >"$sandbox/result/result"
rm "$record"
run running "a.service"
restarted

# The shortcut needs a recorded pass too, not only a finished unit.
printf 'status=failed\ntime=1\n' >"$sandbox/result/result"
rm "$record"
run exited "a.service"
restarted

# Added to a running host whose check failed or was reset: rerun it.
for state in failed dead; do
  printf 'status=failed\ntime=1\n' >"$sandbox/result/result"
  rm "$record"
  run "$state" "a.service"
  restarted
  [[ $(<"$record") == "ignored=a.service" ]]
done

echo "recheck contract passed"
