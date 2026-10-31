#!/usr/bin/env bash
set -euo pipefail

# Publishes whether a game runs on this host as one file: it exists while a
# game runs and for a cooldown after the last one was seen. The CI runner hold,
# the Podman store reset and the user's background builds read only the file.
# A single uncertain scan, typically a process that exits mid-scan, changes
# nothing; several in a row count as a game, so a broken detector holds work
# rather than releasing it.

signal_file=${SIGNAL_FILE:-/run/game-signal/active}
sample_seconds=${SAMPLE_SECONDS:-5}
cooldown_seconds=${COOLDOWN_SECONDS:-60}
uncertain_required=${UNCERTAIN_SAMPLES:-3}
max_iterations=${MAX_ITERATIONS:-0}
uptime_file=${UPTIME_FILE:-/proc/uptime}
notify_bin=${SYSTEMD_NOTIFY_BIN:-systemd-notify}
# shellcheck disable=SC1090
source "${GAME_SCAN_FILE:-$(dirname "${BASH_SOURCE[0]}")/game-scan.sh}"

for value in "$sample_seconds" "$cooldown_seconds" "$uncertain_required" "$max_iterations"; do
  [[ $value =~ ^[0-9]+$ ]] || {
    echo "invalid numeric setting" >&2
    exit 1
  }
done
((uncertain_required > 0)) || {
  echo "invalid numeric setting" >&2
  exit 1
}

now() {
  local uptime rest
  IFS=' ' read -r uptime rest <"$uptime_file" || return 1
  [[ $uptime =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  printf '%s\n' "${uptime%%.*}"
}

publish() {
  local temp
  temp=$(mktemp "${signal_file%/*}/.active.XXXXXX")
  printf '%s\n' "$1" >"$temp"
  chmod 0644 "$temp"
  mv -f -- "$temp" "$signal_file"
}

report() {
  printf 'event=%s %s\n' "$1" "${2:-}" || true
}

mkdir -p "${signal_file%/*}"
# A file left by an earlier run keeps its game until the cooldown has passed
# since this start.
last_seen=0
if [[ -e $signal_file ]]; then
  last_seen=$(now) || exit 1
fi
uncertain=0
game_reason=none
iteration=0
ready=0
while ((max_iterations == 0 || iteration < max_iterations)); do
  iteration=$((iteration + 1))
  current=$(now) || {
    echo "uptime is unreadable" >&2
    exit 1
  }
  if game_scan; then status=0; else status=$?; fi
  case $status in
    0)
      uncertain=0
      last_seen=$current
      if [[ ! -e $signal_file ]]; then
        publish "$game_reason"
        report game_started "reason=$game_reason"
      fi
      ;;
    2)
      uncertain=$((uncertain + 1))
      if ((uncertain >= uncertain_required)); then
        last_seen=$current
        if [[ ! -e $signal_file ]]; then
          publish "uncertain:$game_reason"
          report game_started "reason=uncertain:$game_reason samples=$uncertain"
        fi
      fi
      ;;
    *)
      uncertain=0
      if [[ -e $signal_file ]] && ((current - last_seen >= cooldown_seconds)); then
        rm -f -- "$signal_file"
        report game_ended "cooldown_seconds=$cooldown_seconds"
      fi
      ;;
  esac
  if ((ready == 0)); then
    "$notify_bin" --ready --status="watching for games" || true
    ready=1
  fi
  if ((max_iterations != 0 && iteration >= max_iterations)); then break; fi
  sleep "$sample_seconds"
done
