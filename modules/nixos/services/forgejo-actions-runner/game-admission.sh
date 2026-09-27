#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034
# Shared, read-only process check for the aggregate guard and runner start gate.
# Return 0 when admission is blocked, 1 when clear, 2 on uncertain inspection.
game_uptime_seconds() {
  local uptime rest
  IFS=' ' read -r uptime rest <"${GAME_UPTIME_FILE:-/proc/uptime}" || return 1
  [[ $uptime =~ ^[0-9]+\.[0-9]+$ ]] || return 1
  game_now=${uptime%%.*}
}

game_admission_status() {
  game_reason=clear
  [[ ${GAME_ADMISSION_ENABLED:-0} == 1 ]] || return 1
  local pids result pid exe argv0 basename name now last statline process_state stamp
  local proc_root=${GAME_PROC_ROOT:-/proc}
  if pids=$("${PGREP_BIN:-pgrep}" -u "$GAME_USER" 2>/dev/null); then
    :
  else
    result=$?
    if ((result != 1)); then
      game_reason=scan_error
      return 2
    fi
    pids=
  fi
  for pid in $pids; do
    [[ $pid =~ ^[0-9]+$ ]] || {
      game_reason=scan_error
      return 2
    }
    if ! exe=$(readlink "$proc_root/$pid/exe" 2>/dev/null); then
      [[ ! -e $proc_root/$pid ]] && continue
      if IFS= read -r statline <"$proc_root/$pid/stat" 2>/dev/null; then
        process_state=${statline##*) }
        process_state=${process_state:0:1}
        [[ $process_state == Z || $process_state == X ]] && continue
      fi
      game_reason=scan_error
      return 2
    fi
    [[ ${exe##*/} == wine64-preloader ]] || continue
    if ! IFS= read -r -d '' -t 1 argv0 <"$proc_root/$pid/cmdline" 2>/dev/null; then
      [[ ! -e $proc_root/$pid ]] && continue
      game_reason=scan_error
      return 2
    fi
    basename=${argv0##*/}
    basename=${basename##*\\}
    for name in ${GAME_ARGV0_BASENAMES:-}; do
      if [[ $basename == "$name" ]]; then
        game_uptime_seconds || {
          game_reason=scan_error
          return 2
        }
        stamp="$state_dir/.game-last-seen.$$"
        printf '%s\n' "$game_now" >"$stamp" || {
          game_reason=scan_error
          return 2
        }
        mv -f "$stamp" "$state_dir/game-last-seen" || {
          game_reason=scan_error
          return 2
        }
        game_reason=game_present
        return 0
      fi
    done
  done
  [[ -f $state_dir/game-last-seen && ! -L $state_dir/game-last-seen ]] || {
    [[ ! -e $state_dir/game-last-seen ]] && return 1
    game_reason=scan_error
    return 2
  }
  IFS= read -r last <"$state_dir/game-last-seen" || {
    game_reason=scan_error
    return 2
  }
  [[ $last =~ ^[0-9]+$ ]] || {
    game_reason=scan_error
    return 2
  }
  game_uptime_seconds || {
    game_reason=scan_error
    return 2
  }
  now=$game_now
  if ((now < last || now - last < ${GAME_COOLDOWN_SECONDS:-30})); then
    game_reason=game_cooldown
    return 0
  fi
  return 1
}
