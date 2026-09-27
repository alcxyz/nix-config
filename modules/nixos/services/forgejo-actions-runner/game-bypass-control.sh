#!/usr/bin/env bash
set -euo pipefail

state_dir=${GAME_BYPASS_STATE_DIR:-/run/forgejo-runner-aggregate-pressure}
file=$state_dir/game-bypass

usage() {
  echo 'Usage: game-bypass-control.sh on [--for 2h|30m|7200s] | off | status' >&2
  exit 2
}

[[ -d $state_dir && ! -L $state_dir ]] || {
  echo 'Runner guard state directory is unavailable' >&2
  exit 1
}
[[ $(stat -c '%u:%a' "$state_dir") == "$(id -u):700" ]] || {
  echo 'Runner guard state directory ownership or mode is unexpected' >&2
  exit 1
}

uptime_seconds() {
  local uptime rest
  IFS=' ' read -r uptime rest <"${GAME_UPTIME_FILE:-/proc/uptime}"
  [[ $uptime =~ ^[0-9]+\.[0-9]+$ ]] || return 1
  now=${uptime%%.*}
}

case ${1:-} in
  on)
    if (($# == 1)); then
      value=manual
    elif (($# == 3)) && [[ $2 == --for && $3 =~ ^([1-9][0-9]*)([smh]?)$ ]]; then
      number=${BASH_REMATCH[1]}
      ((${#number} <= 12)) || usage
      case ${BASH_REMATCH[2]} in
        '' | s) factor=1 ;;
        m) factor=60 ;;
        h) factor=3600 ;;
      esac
      duration=$((10#$number * factor))
      uptime_seconds
      value=$((now + duration))
    else
      usage
    fi
    temp=$(mktemp "$state_dir/.game-bypass.XXXXXX")
    trap 'rm -f -- "$temp"' EXIT
    chmod 0600 "$temp"
    printf '%s\n' "$value" > "$temp"
    mv -fT -- "$temp" "$file"
    trap - EXIT
    ;;
  off)
    (($# == 1)) || usage
    rm -f -- "$file"
    ;;
  status)
    (($# == 1)) || usage
    if [[ ! -e $file && ! -L $file ]]; then
      echo off
      exit 0
    fi
    [[ -f $file && ! -L $file ]] || { echo invalid; exit 1; }
    IFS= read -r value < "$file" || { echo invalid; exit 1; }
    if [[ $value == manual ]]; then
      echo manual
    elif [[ $value =~ ^[1-9][0-9]{0,17}$ ]]; then
      uptime_seconds
      if ((now < value)); then
        echo "timed $((value - now)) seconds remaining"
      else
        echo expired
      fi
    else
      echo invalid
      exit 1
    fi
    ;;
  *) usage ;;
esac
