#!/usr/bin/env bash
set -euo pipefail

state_dir=${STATE_DIR:-/run/forgejo-runner-aggregate-pressure}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
timeout_seconds=${GATE_TIMEOUT_SECONDS:-60}
[[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] || exit 1

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

for marker in owned pending drain-owned drain-pending resume-pending drain-disowned teardown-required; do
  [[ ! -e $state_dir/$marker ]] || exit 1
done

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
