#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
  echo 'usage: record-success MARKER' >&2
  exit 2
fi

marker=$1
case ${SERVICE_RESULT:-}:${EXIT_CODE:-}:${EXIT_STATUS:-} in
  success:exited:0) ;;
  *) exit 0 ;;
esac

state_dir=${marker%/*}
if [[ ! -d $state_dir ]]; then
  echo "success marker directory is unavailable: $state_dir" >&2
  exit 1
fi

temporary=$(mktemp "$state_dir/.success.XXXXXX")
cleanup() {
  rm -f -- "$temporary"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

timestamp=$(date +%s)
[[ $timestamp =~ ^[1-9][0-9]{0,17}$ ]] || {
  echo 'current wall-clock timestamp is invalid' >&2
  exit 1
}
printf '%s\n' "$timestamp" >"$temporary"
chmod 0600 "$temporary"
mv -fT -- "$temporary" "$marker"
trap - EXIT HUP INT TERM
