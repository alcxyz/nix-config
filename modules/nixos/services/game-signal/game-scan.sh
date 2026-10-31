#!/usr/bin/env bash
# shellcheck disable=SC2034
# Read-only scan for a running game, shared by the game signal and the reboot
# guard. game_scan returns 0 when a game runs, 1 when none does and 2 when the
# scan is uncertain, and sets game_reason. It writes nothing.
#
#   GAME_USER                   account whose processes are scanned
#   GAME_WINE_ARGV0_BASENAMES   Wine games: the first argument of the user's
#                               wine64-preloader processes, by basename
#   GAME_PROCESS_NAMES          exact process names (comm) of the user
#   GAME_STREAM_UDP_PORTS       UDP ports a stream server binds only while a
#                               client streams
game_scan() {
  local pids result pid exe argv0 basename name statline process_state port sockets
  local proc_root=${GAME_PROC_ROOT:-/proc}
  game_reason=none

  # A stream server's port, whoever runs the server: SteamHeadless runs
  # Sunshine in a container on the host network.
  for port in ${GAME_STREAM_UDP_PORTS:-}; do
    if ! sockets=$("${SS_BIN:-ss}" -Hanu "( sport = :$port )" 2>/dev/null); then
      game_reason=stream_scan_error
      return 2
    fi
    if [[ -n $sockets ]]; then
      game_reason="stream:$port"
      return 0
    fi
  done
  [[ -n ${GAME_USER:-} ]] || return 1

  for name in ${GAME_PROCESS_NAMES:-}; do
    if "${PGREP_BIN:-pgrep}" -u "$GAME_USER" -x "$name" >/dev/null 2>&1; then
      game_reason="process:$name"
      return 0
    else
      result=$?
      if ((result != 1)); then
        game_reason=process_scan_error
        return 2
      fi
    fi
  done

  [[ -n ${GAME_WINE_ARGV0_BASENAMES:-} ]] || return 1
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
      # A process that exits during the scan has no executable link left.
      [[ ! -e $proc_root/$pid ]] && continue
      if IFS= read -r statline <"$proc_root/$pid/stat" 2>/dev/null; then
        process_state=${statline##*) }
        process_state=${process_state:0:1}
        [[ $process_state == Z || $process_state == X ]] && continue
      else
        [[ ! -e $proc_root/$pid ]] && continue
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
    for name in $GAME_WINE_ARGV0_BASENAMES; do
      if [[ $basename == "$name" ]]; then
        game_reason="wine:$name"
        return 0
      fi
    done
  done
  return 1
}
