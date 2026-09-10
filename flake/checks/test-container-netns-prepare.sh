#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: test-container-netns-prepare PREPARE_SCRIPT" >&2
  exit 2
fi

prepare_script=$1
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
mock_bin=$work_dir/bin
call_log=$work_dir/calls
mkdir -p "$mock_bin"
real_bash=$(command -v bash)

printf '#!%s\n' "$real_bash" >"$mock_bin/mock-command"
# These single-quoted lines intentionally defer expansion to the mock process.
# shellcheck disable=SC2016
printf '%s\n' \
  'set -euo pipefail' \
  'command_name=${0##*/}' \
  'printf "%s %s\n" "$command_name" "$*" >>"$CALL_LOG"' \
  'case "$command_name" in' \
  '  container-netns-audit) exit "${AUDIT_STATUS:-0}" ;;' \
  '  systemctl)' \
  '    if [[ ${1:-} == is-system-running ]]; then' \
  '      printf "%s\n" "${SYSTEM_STATE:-running}"' \
  '      exit 0' \
  '    fi' \
  '    if [[ ${1:-} == is-active && ${3:-} == "${ACTIVE_RUNTIME:-}" ]]; then' \
  '      exit 0' \
  '    fi' \
  '    exit 1' \
  '    ;;' \
  '  install | flock | mountpoint | mount) exit 0 ;;' \
  'esac' \
  'exit 1' >>"$mock_bin/mock-command"
chmod +x "$mock_bin/mock-command"

for command in container-netns-audit systemctl install flock mountpoint mount; do
  ln -s mock-command "$mock_bin/$command"
done

assert_no_mutation() {
  if grep -Eq '^(install|flock|mountpoint|mount) ' "$call_log"; then
    echo "preparation guard reached a mutating command" >&2
    cat "$call_log" >&2
    exit 1
  fi
}

: >"$call_log"
CALL_LOG=$call_log AUDIT_STATUS=0 SYSTEM_STATE=running ACTIVE_RUNTIME=docker.service \
  PATH="$mock_bin:$PATH" bash "$prepare_script"
assert_no_mutation
grep -Fxq 'container-netns-audit ' "$call_log"
if [[ $(wc -l <"$call_log") -ne 1 ]]; then
  echo "healthy live topology did more than audit" >&2
  exit 1
fi

: >"$call_log"
if CALL_LOG=$call_log AUDIT_STATUS=1 SYSTEM_STATE=running \
  PATH="$mock_bin:$PATH" bash "$prepare_script" >"$work_dir/post-boot.out" 2>"$work_dir/post-boot.err"; then
  echo "unhealthy topology was accepted after boot" >&2
  exit 1
fi
assert_no_mutation
grep -Fq 'systemctl is-system-running' "$call_log"
grep -Fq 'refusing to change /run/netns after system startup' "$work_dir/post-boot.err"

for runtime in docker.service k3s.service; do
  : >"$call_log"
  if CALL_LOG=$call_log AUDIT_STATUS=1 SYSTEM_STATE=starting ACTIVE_RUNTIME=$runtime \
    PATH="$mock_bin:$PATH" bash "$prepare_script" >"$work_dir/$runtime.out" 2>"$work_dir/$runtime.err"; then
    echo "unhealthy topology was accepted while $runtime was active" >&2
    exit 1
  fi
  assert_no_mutation
  grep -Fq "systemctl is-active --quiet $runtime" "$call_log"
  grep -Fq "refusing to change /run/netns while $runtime is active" "$work_dir/$runtime.err"
done
