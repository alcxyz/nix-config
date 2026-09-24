#!/usr/bin/env bash
set -euo pipefail

state_dir=${STATE_DIR:-/run/forgejo-runner-aggregate-pressure}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
runner_units_text=${RUNNER_UNITS:-}

# ExecCondition exits 1 to skip a start without a restart attempt. The
# persisted registry belongs to the running guard; daemon-reloaded unit
# environment may describe a new configuration while its old process lives.
[[ -n $runner_units_text && -d $state_dir ]] || exit 1
IFS=$' \t\n' read -r -d '' -a runner_units <<< "$runner_units_text" || true
((${#runner_units[@]} > 1)) || exit 1
[[ ${runner_units[0]} == forgejo-actions-runner.service ]] || exit 1
[[ ${runner_units[1]} == forgejo-podman-runner.service ]] || exit 1

exec 9>"$state_dir/lifecycle.lock"
flock -w 60 -x 9 || exit 1
[[ -f $state_dir/runner-units && ! -L $state_dir/runner-units ]] || exit 1
[[ $(cat "$state_dir/runner-units") == "$(printf '%s\n' "${runner_units[@]}")" ]] || exit 1
[[ -d $state_dir/runners/forgejo-podman-runner.service ]] || exit 1

for marker in owned pending teardown-required; do
  [[ ! -e $state_dir/$marker ]] || exit 1
done
timeout --foreground 5s "$systemctl_bin" is-active --quiet \
  forgejo-runner-io-pressure-guard.service || exit 1
[[ $(timeout --foreground 5s "$systemctl_bin" show --property=FreezerState \
  --value forgejobuilds.slice) == running ]] || exit 1
