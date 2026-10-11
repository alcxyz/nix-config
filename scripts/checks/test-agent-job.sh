#!/usr/bin/env bash
# Contract tests for agent-job (nix-config #612), with systemd-run and
# systemctl replaced by stubs that run the unit as a background process.
set -euo pipefail

src=$PWD/modules/home-manager/programs/ai/agent-job.sh
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$tmp/bin" "$tmp/stub" "$tmp/work dir"
# The Nix build sandbox has no /usr/bin/env, so the stubs name bash directly.
shebang="#!$(command -v bash)"
# The Nix wrapper adds these shell options; do the same here.
{
  echo "$shebang"
  echo 'set -euo pipefail'
  cat "$src"
} >"$tmp/bin/agent-job"

{
  echo "$shebang"
  cat <<'EOF'
# Stub: records its arguments, then runs ExecStart and ExecStopPost like a
# transient unit, with output appended to the StandardOutput file.
set -euo pipefail
printf '%s\n' "$@" >"$STUB/systemd-run.args"
[[ -n ${STUB_START_FAILS-} ]] && exit 1
while [[ $1 != -- ]]; do
  case $1 in
    --unit=*) unit=${1#--unit=} ;;
    -p)
      shift
      case $1 in
        StandardOutput=append:*) log=${1#StandardOutput=append:} ;;
        ExecStopPost=*) read -ra post <<<"${1#ExecStopPost=}" ;;
      esac
      ;;
  esac
  shift
done
shift
echo active >"$STUB/$unit.state"
(
  "$@" >>"$log" 2>&1 &
  echo $! >"$STUB/$unit.pid"
  rc=0
  wait $! || rc=$?
  if ((rc > 128)); then
    EXIT_CODE=killed EXIT_STATUS=TERM "${post[@]}"
  else
    EXIT_CODE=exited EXIT_STATUS=$rc "${post[@]}"
  fi
  echo inactive >"$STUB/$unit.state"
) &
EOF
} >"$tmp/bin/systemd-run"

{
  echo "$shebang"
  cat <<'EOF'
set -euo pipefail
unit=${*: -1}
case $* in
  "--user show -P ActiveState "*) cat "$STUB/$unit.state" 2>/dev/null || echo inactive ;;
  "--user stop "*)
    kill "$(<"$STUB/$unit.pid")"
    until [[ $(<"$STUB/$unit.state") == inactive ]]; do sleep 0.1; done
    ;;
  *) exit 1 ;;
esac
EOF
} >"$tmp/bin/systemctl"
chmod +x "$tmp/bin/"*

export PATH="$tmp/bin:$PATH" STUB="$tmp/stub" AGENT_JOB_STATE_DIR="$tmp/state"
jobs_dir=$tmp/state

expect_exit() {
  local want=$1 got=0
  shift
  "$@" >"$tmp/out" 2>&1 || got=$?
  [[ $got == "$want" ]] || fail "$* exited $got, want $want: $(<"$tmp/out")"
}

# Arguments reach the command unchanged, including systemd-special characters.
cd "$tmp/work dir"
# shellcheck disable=SC2016 # the literal $HOME must reach the job
agent-job start args -- printf '%s|' 'a b' '$HOME' '%n' "it's" >/dev/null
cd - >/dev/null
expect_exit 0 agent-job wait args 1
[[ $(<"$jobs_dir/args/log") == "a b|\$HOME|%n|it's|" ]] || fail "arguments changed: $(<"$jobs_dir/args/log")"
grep -qx "cwd=$tmp/work dir" "$jobs_dir/args/info" || fail "cwd not recorded"
grep -qx -- "--same-dir" "$tmp/stub/systemd-run.args" || fail "job does not keep the caller's directory"
grep -qx -- "--collect" "$tmp/stub/systemd-run.args" || fail "unit is not collected"
grep -qx -- "--setenv=PATH=$PATH" "$tmp/stub/systemd-run.args" || fail "caller PATH not passed"
[[ $(grep -c -- '--setenv' "$tmp/stub/systemd-run.args") == 1 ]] || fail "more than PATH passed to the unit"
grep -q 'finished at .* (exited 0)' "$tmp/out" || fail "wait did not report success: $(<"$tmp/out")"

# wait reports a failed job as 1, whatever its status, and shows its log.
agent-job start bad -- sh -c 'echo partial; exit 70' >/dev/null
expect_exit 1 agent-job wait bad 1
grep -q 'finished .*(exited 70)' "$tmp/out" || fail "failed result not reported"
grep -qx partial "$tmp/out" || fail "log tail not shown"

# A finished job keeps its name until it is cleaned.
expect_exit 73 agent-job start bad -- true
[[ $(<"$jobs_dir/bad/info") == *"command=sh -c"* ]] || fail "duplicate start overwrote the job"
grep -q 'agent-job clean bad' "$tmp/out" || fail "duplicate start did not point to clean"
expect_exit 0 agent-job clean bad
[[ ! -e $jobs_dir/bad ]] || fail "clean left the job directory"

# A running job reports as running, refuses clean, and stops as killed.
agent-job start slow -- sleep 30 >/dev/null
expect_exit 0 agent-job status slow
grep -q 'slow: running since' "$tmp/out" || fail "status did not show running: $(<"$tmp/out")"
grep -q "command: sleep 30" "$tmp/out" || fail "status did not show the command"
expect_exit 73 agent-job start slow -- true
expect_exit 73 agent-job clean slow
expect_exit 0 agent-job list
grep -q 'args: finished' "$tmp/out" || fail "list missed a finished job: $(<"$tmp/out")"
grep -q 'slow: running' "$tmp/out" || fail "list missed a running job: $(<"$tmp/out")"
expect_exit 0 agent-job stop slow
grep -q 'finished .*(killed TERM)' "$tmp/out" || fail "stop result not recorded: $(<"$tmp/out")"
expect_exit 1 agent-job wait slow 1
expect_exit 1 agent-job stop slow

# A unit that ended without recording a result is reported, not waited on.
mkdir -p "$jobs_dir/lost"
printf 'started=x\ncwd=/\ncommand=true\n' >"$jobs_dir/lost/info"
expect_exit 70 agent-job wait lost 1
grep -q 'ended without a recorded result' "$tmp/out" || fail "lost job not reported"

# A failed start leaves nothing behind.
STUB_START_FAILS=1 expect_exit 69 agent-job start broken -- true
[[ ! -e $jobs_dir/broken ]] || fail "failed start left a job directory"

# A start that loses the race for a name leaves the existing directory alone.
mkdir "$jobs_dir/taken"
STUB_START_FAILS=1 expect_exit 73 agent-job start taken -- true
[[ -d $jobs_dir/taken ]] || fail "losing start removed another job's directory"

# Usage errors.
expect_exit 64 agent-job
expect_exit 64 agent-job start Bad -- true
expect_exit 64 agent-job start ../x -- true
expect_exit 64 agent-job start x true
expect_exit 64 agent-job start x --
expect_exit 64 agent-job wait args 0
expect_exit 66 agent-job wait missing
expect_exit 66 agent-job log missing

echo "agent-job tests passed"
