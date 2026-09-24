#!/usr/bin/env bash
set -euo pipefail

state_dir=${STATE_DIR:-/run/forgejo-runner-aggregate-pressure}
cgroup_root=${CGROUP_ROOT:-/sys/fs/cgroup}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
timeout_seconds=${TEARDOWN_TIMEOUT_SECONDS:-270}
primary_runner=forgejo-actions-runner.service
runner_units_text=${RUNNER_UNITS:-$primary_runner}
unit=forgejobuilds.slice
cgroup="$cgroup_root/forgejobuilds.slice"

fail() {
  printf 'aggregate lifecycle: %s\n' "$1" >&2
  exit 1
}

[[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] || fail "invalid teardown timeout"
IFS=$' \t\n' read -r -d '' -a runner_units <<< "$runner_units_text" || true
((${#runner_units[@]} > 0)) || fail "runner unit list is empty"
[[ ${runner_units[0]} == "$primary_runner" ]] || fail "primary runner must remain first"
for candidate in "${runner_units[@]}"; do
  [[ $candidate =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || fail "invalid runner unit name"
done
deadline=$((SECONDS + timeout_seconds))
budget() {
  local cap=$1
  budget_seconds=$((deadline - SECONDS))
  ((budget_seconds > 0)) || fail "aggregate teardown deadline expired"
  if ((budget_seconds > cap)); then budget_seconds=$cap; fi
}
property() {
  budget 5
  timeout --foreground "${budget_seconds}s" "$systemctl_bin" \
    show --property="$1" --value "$2"
}

[[ -d $state_dir ]] || fail "guard state directory is missing"
exec 9>"$state_dir/lifecycle.lock"
budget "$timeout_seconds"
flock -w "$budget_seconds" -x 9 || fail "timed out waiting for guard transition"

# A changed configuration cannot orphan a previously drained runner. The
# guard will reject the mismatch; teardown still finishes every known runner.
if [[ -e $state_dir/runner-units ]]; then
  mapfile -t previous_units < "$state_dir/runner-units"
  for candidate in "${previous_units[@]}"; do
    [[ $candidate =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || fail "invalid persisted runner unit name"
    present=0
    for configured in "${runner_units[@]}"; do
      [[ $candidate != "$configured" ]] || present=1
    done
    ((present == 1)) || runner_units+=("$candidate")
  done
fi

scope=$(property ControlGroup "$unit") || fail "cannot inspect aggregate cgroup"
[[ $scope == /forgejobuilds.slice ]] || fail "aggregate cgroup scope changed"
[[ -f $cgroup/cgroup.events && -f $cgroup/cgroup.kill ]] ||
  fail "aggregate cgroup kill interface is unavailable"
[[ $(readlink -f -- "$cgroup") == "$cgroup" ]] || fail "aggregate cgroup path is not canonical"

freezer=$(property FreezerState "$unit") || fail "cannot inspect aggregate freezer"
guard=$(property ActiveState forgejo-runner-io-pressure-guard.service) ||
  fail "cannot inspect pressure guard"
case "$freezer" in
  running | frozen | freezing | thawing) ;;
  *) fail "aggregate freezer transition is ambiguous" ;;
esac

# An ordinary unfrozen daemon stop is graceful. A frozen cgroup cannot run
# systemd's stop signals, and guard loss must terminate all existing workers.
if [[ $freezer == running && $guard == active ]]; then
  exit 0
fi

: > "$state_dir/teardown-required"
budget 10
# The inner shell receives the cgroup path as $1.
# shellcheck disable=SC2016
timeout --foreground "${budget_seconds}s" bash -c 'printf "1\n" > "$1"' \
  bash "$cgroup/cgroup.kill" || fail "could not terminate aggregate descendants"

while :; do
  if [[ ! -e $cgroup/cgroup.events ]]; then
    break # systemd removed the exact cgroup after its last process exited.
  fi
  budget 5
  # $1 and $2 are awk fields.
  # shellcheck disable=SC2016
  populated=$(timeout --foreground "${budget_seconds}s" awk \
    '$1 == "populated" { print $2 }' "$cgroup/cgroup.events") ||
    fail "cannot inspect aggregate population"
  [[ $populated == 0 || $populated == 1 ]] || fail "invalid aggregate population state"
  [[ $populated == 0 ]] && break
  ((SECONDS < deadline)) || fail "aggregate descendants did not exit"
  sleep 1
done

# A runner can wait for an admitted job much longer than the daemon's stop
# budget. Workers are gone now, so finish every pending runner stop. All
# queries and waits consume the one aggregate deadline above.
for runner_unit in "${runner_units[@]}"; do
  runner=$(property ActiveState "$runner_unit") ||
    fail "cannot inspect runner during aggregate teardown"
  case "$runner" in
    active | activating | deactivating)
      budget 5
      if ! timeout --foreground "${budget_seconds}s" "$systemctl_bin" kill --signal=KILL --kill-whom=all \
        "$runner_unit"; then
        runner=$(property ActiveState "$runner_unit") ||
          fail "cannot recheck runner after kill request"
        [[ $runner == inactive || $runner == failed ]] ||
          fail "could not terminate drained runner"
      fi
      while :; do
        runner=$(property ActiveState "$runner_unit") ||
          fail "cannot verify runner termination"
        case "$runner" in
          inactive | failed) break ;;
          active | activating | deactivating)
            ((SECONDS < deadline)) || fail "runner did not finish stopping"
            sleep 1
            ;;
          *) fail "runner state is ambiguous after termination" ;;
        esac
      done
      ;;
    inactive | failed) ;;
    *) fail "runner state is ambiguous during aggregate teardown" ;;
  esac
done

# Ownership is a positive assertion. Pending transitions, manual freezes and
# changed ownership are left frozen for explicit recovery.
if [[ $freezer == frozen && -e $state_dir/owned && ! -e $state_dir/pending ]]; then
  [[ $(property FreezerState "$unit") == frozen ]] ||
    fail "owned aggregate freeze changed during teardown"
  budget "$timeout_seconds"
  SYSTEMD_BUS_TIMEOUT="${budget_seconds}s" timeout --foreground "${budget_seconds}s" \
    "$systemctl_bin" thaw "$unit" || fail "owned aggregate thaw failed"
  [[ $(property FreezerState "$unit") == running ]] ||
    fail "aggregate remained frozen after owned thaw"
  rm "$state_dir/owned"
fi
