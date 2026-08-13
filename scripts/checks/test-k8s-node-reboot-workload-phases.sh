#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$ROOT/scripts/ops/k8s-node-reboot.sh"

export NODE=worker-a
export SETTLE_TIMEOUT=1s
WORKLOADS="$TMP/workloads"
PREFLIGHT_CALLS="$TMP/preflight-calls"
RETURN_CALLS="$TMP/return-calls"

cat >"$WORKLOADS" <<'EOF'
default	deployment/pinned
default	deployment/portable
EOF

workload_requires_target_node() {
  [[ "$2" == "deployment/pinned" ]]
}

wait_for_controller_ready_floor() {
  printf '%s/%s\n' "$1" "$2" >>"$PREFLIGHT_CALLS"
}

kubectl() {
  if [[ "$*" == *"rollout status"* ]]; then
    printf '%s\n' "$*" >>"$RETURN_CALLS"
    return 0
  fi

  if [[ "$*" == *"get deployment/portable"* ]]; then
    printf '1'
    return 0
  fi

  printf 'unexpected kubectl call: %s\n' "$*" >&2
  return 1
}

wait_for_displaced_workload_survivability "$WORKLOADS"

grep -Fxq 'default/deployment/portable' "$PREFLIGHT_CALLS"
if grep -Fq 'deployment/pinned' "$PREFLIGHT_CALLS"; then
  printf 'target-pinned workload was checked before its node returned\n' >&2
  exit 1
fi

wait_for_workloads "$WORKLOADS"

grep -Fq 'deployment/pinned' "$RETURN_CALLS"
grep -Fq 'deployment/portable' "$RETURN_CALLS"

printf 'k8s node reboot workload phase tests: PASS\n'
