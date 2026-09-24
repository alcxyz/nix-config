#!/usr/bin/env bash
set -euo pipefail

state_dir=${STATE_DIR:-/run/forgejo-runner-aggregate-pressure}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
timeout_seconds=${GATE_TIMEOUT_SECONDS:-60}
primary_runner=forgejo-actions-runner.service
runner_unit=${RUNNER_UNIT:-$primary_runner}
runner_units_text=${RUNNER_UNITS:-$primary_runner}
[[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] || exit 1
IFS=$' \t\n' read -r -d '' -a runner_units <<< "$runner_units_text" || true
((${#runner_units[@]} > 0)) || exit 1
[[ ${runner_units[0]} == "$primary_runner" ]] || exit 1
[[ $runner_unit =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || exit 1
runner_known=0
seen_units=()
for candidate in "${runner_units[@]}"; do
  [[ $candidate =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || exit 1
  for previous in "${seen_units[@]}"; do
    [[ $candidate != "$previous" ]] || exit 1
  done
  seen_units+=("$candidate")
  [[ $runner_unit != "$candidate" ]] || runner_known=1
done
((runner_known == 1)) || exit 1

# ExecCondition exits 1 to skip a start without turning it into a restart
# failure. Boot may reach the daemon before the lifecycle service is armed.
deadline=$((SECONDS + timeout_seconds))
while :; do
  remaining=$((deadline - SECONDS))
  ((remaining > 0)) || exit 1
  attempt_timeout=5
  ((remaining < attempt_timeout)) && attempt_timeout=$remaining
  if timeout --foreground "${attempt_timeout}s" "$systemctl_bin" is-active --quiet \
    forgejo-runner-aggregate-lifecycle.service; then
    break
  fi
  sleep 1
done

[[ -d $state_dir ]] || exit 1
exec 9>"$state_dir/lifecycle.lock"
remaining=$((deadline - SECONDS))
((remaining > 0)) || exit 1
flock -w "$remaining" -x 9 || exit 1

if [[ -e $state_dir/runner-units ]]; then
  [[ $(cat "$state_dir/runner-units") == "$(printf '%s\n' "${runner_units[@]}")" ]] || exit 1
else
  ((${#runner_units[@]} == 1)) || exit 1
fi
for path in "$state_dir"/runners/*; do
  [[ -e $path || -L $path ]] || continue
  [[ -d $path && ! -L $path ]] || exit 1
  known=0
  for candidate in "${runner_units[@]:1}"; do
    [[ $path != "$state_dir/runners/$candidate" ]] || known=1
  done
  ((known == 1)) || exit 1
done
for marker in owned pending teardown-required; do
  [[ ! -e $state_dir/$marker ]] || exit 1
done
for candidate in "${runner_units[@]}"; do
  if [[ $candidate == "$primary_runner" ]]; then
    candidate_state=$state_dir
  else
    candidate_state=$state_dir/runners/$candidate
    [[ -d $candidate_state ]] || exit 1
  fi
  for marker in drain-pending resume-pending drain-disowned; do
    [[ ! -e $candidate_state/$marker ]] || exit 1
  done
done
if [[ $runner_unit == "$primary_runner" ]]; then
  runner_state=$state_dir
else
  runner_state=$state_dir/runners/$runner_unit
fi
[[ ! -e $runner_state/drain-owned ]] || exit 1

remaining=$((deadline - SECONDS))
((remaining > 0)) || exit 1
((remaining < 5)) && query_timeout=$remaining || query_timeout=5
[[ $(timeout --foreground "${query_timeout}s" "$systemctl_bin" \
  show --property=FreezerState --value forgejobuilds.slice) == running ]] || exit 1

remaining=$((deadline - SECONDS))
((remaining > 0)) || exit 1
((remaining < 5)) && query_timeout=$remaining || query_timeout=5
timeout --foreground "${query_timeout}s" "$systemctl_bin" is-active --quiet \
  forgejo-runner-io-pressure-guard.service
