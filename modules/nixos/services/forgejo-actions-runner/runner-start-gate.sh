#!/usr/bin/env bash
set -euo pipefail

# ExecCondition of every runner unit (ADR-0106). Exit 1 skips the start
# without a restart attempt. It refuses while a hold reason applies and then
# leaves the runner's `held` marker, so the runner hold starts the runner once
# the reason ends: boot, a switch or a Podman store reset cannot start a
# runner behind a game or a full disk. The start lock orders every start after
# a store reset's rename.

state_dir=${STATE_DIR:-/run/forgejo-runner-hold}
runner_unit=${RUNNER_UNIT:?}
timeout_seconds=${GATE_TIMEOUT_SECONDS:-60}
game_enabled=${GAME_ENABLED:-0}
game_file=${GAME_FILE:-/run/game-signal/active}
game_unit=${GAME_UNIT:-game-signal.service}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
# shellcheck disable=SC1090
source "${DISK_HELPER_FILE:-$(dirname "${BASH_SOURCE[0]}")/disk-space-admission.sh}"

[[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] || exit 1
[[ $runner_unit =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || exit 1
[[ $game_enabled == 0 || $game_enabled == 1 ]] || exit 1
[[ ! -L $state_dir ]] || exit 1
runner_state=$state_dir/runners/$runner_unit
install -d -m 0700 "$state_dir" "$state_dir/runners" "$runner_state"
[[ ! -L $state_dir/start.lock ]] || exit 1
exec 9>"$state_dir/start.lock"
flock -w "$timeout_seconds" -x 9 || exit 1

hold() {
  : >"$runner_state/held"
  echo "runner start held: $1"
  exit 1
}
if ((game_enabled == 1)); then
  timeout --foreground 5s "$systemctl_bin" is-active --quiet "$game_unit" || hold game_signal_unavailable
  [[ ! -e $game_file ]] || hold game
fi
if disk_space_status; then disk_status=0; else disk_status=$?; fi
# Below the floor the gate starts the disk hold itself, which the runner hold
# ends only above the recovery floors; between the floors a hold continues.
if ((disk_status == 1 || disk_status == 4)); then
  : >"$state_dir/disk-held"
  hold disk_space
fi
if ((disk_status == 3)) && [[ -e $state_dir/disk-held ]]; then
  hold disk_space
fi
exit 0
