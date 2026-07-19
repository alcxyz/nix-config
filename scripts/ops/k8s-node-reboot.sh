#!/usr/bin/env bash
set -euo pipefail

HOST=""
NODE=""
SSH_TARGET=""
ACTION=""
SKIP_DRAIN=false
FORCE_DRAIN=false
BYPASS_PDB=false
LEAVE_CORDONED=false
RESUME_MAINTENANCE=false
CHECK_ONLY=false
DRAIN_TIMEOUT="10m"
READY_TIMEOUT="10m"
SETTLE_TIMEOUT="15m"
SSH_TIMEOUT_SECONDS=900
POLL_SECONDS=5
REQUIRE_LONGHORN_BACKUP_TARGET=false
MIN_FREE_POD_SLOTS=20
MIN_LONGHORN_REPLICAS=3
MIN_SURVIVING_LONGHORN_REPLICAS=2
REMOTE_BOOT_ID=""
WORKLOADS_FILE=""

usage() {
  cat <<'EOF'
Usage: kreboot [options] <host>
       koff [options] <host>
       kon [options] <host>

Kubernetes-aware node power helpers.

Commands:
  kreboot                  Cordon, drain, reboot, wait for Ready, uncordon.
  koff                     Cordon, drain, power off, leave cordoned.
  kon                      Wait for host/node to return, uncordon, settle.

Options:
  --node <name>            Kubernetes node name. Defaults to <host>.
  --ssh-target <target>    SSH target. Defaults to <host>.
  --skip-drain             Cordon only, then reboot. Use for intentional disruption.
  --force-drain            Pass --force to kubectl drain for unmanaged pods.
  --bypass-pdb             Use pod deletion instead of eviction; ignores PDBs.
  --leave-cordoned         Keep the node cordoned after it returns.
  --resume-maintenance     Reuse an already cordoned, drained, and detached
                           node for another power cycle. Fails closed if the
                           maintenance-state gates do not pass.
  --check-only             Validate preflight or resumed-maintenance gates
                           without cordoning, draining, or powering the host.
  --drain-timeout <dur>    kubectl drain duration. Default: 10m.
  --ready-timeout <dur>    kubectl wait duration. Default: 10m.
  --settle-timeout <dur>   Workload/Longhorn health wait duration. Default: 15m.
  --ssh-timeout <seconds>  SSH return timeout. Default: 900.
  --require-longhorn-backup-target
                           Fail if the Longhorn backup target is unavailable.
  --min-free-pod-slots N   Require N aggregate Pod slots after evacuation on
                           the remaining stable nodes.
                           Default: 20.
  -h, --help               Show this help.

Requires kubectl access to the target cluster and SSH sudo rights on the host.
EOF
}

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cleanup_workloads_file() {
  if [[ -n "$WORKLOADS_FILE" ]]; then
    rm -f -- "$WORKLOADS_FILE"
  fi
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

duration_to_seconds() {
  local duration="$1"

  case "$duration" in
    *s)
      printf '%s\n' "${duration%s}"
      ;;
    *m)
      printf '%s\n' "$((${duration%m} * 60))"
      ;;
    *h)
      printf '%s\n' "$((${duration%h} * 3600))"
      ;;
    *[!0-9]*)
      die "unsupported duration: ${duration}"
      ;;
    *)
      printf '%s\n' "$duration"
      ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --node)
        [[ $# -ge 2 ]] || die "--node requires a value"
        NODE="$2"
        shift 2
        ;;
      --ssh-target)
        [[ $# -ge 2 ]] || die "--ssh-target requires a value"
        SSH_TARGET="$2"
        shift 2
        ;;
      --skip-drain)
        SKIP_DRAIN=true
        shift
        ;;
      --force-drain)
        FORCE_DRAIN=true
        shift
        ;;
      --bypass-pdb)
        BYPASS_PDB=true
        shift
        ;;
      --leave-cordoned)
        LEAVE_CORDONED=true
        shift
        ;;
      --resume-maintenance)
        RESUME_MAINTENANCE=true
        shift
        ;;
      --check-only)
        CHECK_ONLY=true
        shift
        ;;
      --drain-timeout)
        [[ $# -ge 2 ]] || die "--drain-timeout requires a value"
        DRAIN_TIMEOUT="$2"
        shift 2
        ;;
      --ready-timeout)
        [[ $# -ge 2 ]] || die "--ready-timeout requires a value"
        READY_TIMEOUT="$2"
        shift 2
        ;;
      --settle-timeout)
        [[ $# -ge 2 ]] || die "--settle-timeout requires a value"
        SETTLE_TIMEOUT="$2"
        shift 2
        ;;
      --ssh-timeout)
        [[ $# -ge 2 ]] || die "--ssh-timeout requires a value"
        SSH_TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --require-longhorn-backup-target)
        REQUIRE_LONGHORN_BACKUP_TARGET=true
        shift
        ;;
      --min-free-pod-slots)
        [[ $# -ge 2 ]] || die "--min-free-pod-slots requires a value"
        [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--min-free-pod-slots must be a positive integer"
        MIN_FREE_POD_SLOTS="$2"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --*)
        die "unknown option: $1"
        ;;
      *)
        [[ -z "$HOST" ]] || die "only one host can be supplied"
        HOST="$1"
        shift
        ;;
    esac
  done

  [[ -n "$HOST" ]] || {
    usage >&2
    exit 2
  }

  NODE="${NODE:-$HOST}"
  SSH_TARGET="${SSH_TARGET:-$HOST}"

  ACTION="${K8S_NODE_POWER_ACTION:-}"

  if [[ -z "$ACTION" ]]; then
    case "$(basename "$0")" in
      koff)
        ACTION="off"
        ;;
      kon)
        ACTION="on"
        ;;
      kreboot | k8s-node-reboot | k8s-node-reboot.sh)
        ACTION="reboot"
        ;;
      *)
        ACTION="reboot"
        ;;
    esac
  fi

  if [[ "$ACTION" == "off" ]]; then
    LEAVE_CORDONED=true
  fi
}

workload_key_for_pod() {
  local namespace="$1"
  local pod="$2"
  local owner_kind
  local owner_name
  local rs_owner_kind
  local rs_owner_name

  owner_kind=$(
    kubectl -n "$namespace" get pod "$pod" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true
  )
  owner_name=$(
    kubectl -n "$namespace" get pod "$pod" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true
  )

  case "$owner_kind" in
    DaemonSet | Job | Node | "")
      return 0
      ;;
    StatefulSet)
      printf '%s\tstatefulset/%s\n' "$namespace" "$owner_name"
      ;;
    ReplicaSet)
      rs_owner_kind=$(
        kubectl -n "$namespace" get replicaset "$owner_name" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true
      )
      rs_owner_name=$(
        kubectl -n "$namespace" get replicaset "$owner_name" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true
      )

      if [[ "$rs_owner_kind" == "Deployment" && -n "$rs_owner_name" ]]; then
        printf '%s\tdeployment/%s\n' "$namespace" "$rs_owner_name"
      else
        printf '%s\treplicaset/%s\n' "$namespace" "$owner_name"
      fi
      ;;
    *)
      printf '%s\t%s/%s\n' "$namespace" "${owner_kind,,}" "$owner_name"
      ;;
  esac
}

collect_displaced_workloads() {
  local pod_list
  local namespace
  local pod

  pod_list=$(mktemp)
  kubectl get pods --all-namespaces \
    --field-selector "spec.nodeName=${NODE}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' >"$pod_list"

  while IFS=$'\t' read -r namespace pod; do
    [[ -n "$namespace" && -n "$pod" ]] || continue
    workload_key_for_pod "$namespace" "$pod"
  done <"$pod_list" | sort -u

  rm -f "$pod_list"
}

wait_for_workloads() {
  local workloads_file="$1"
  local namespace
  local workload
  local selector
  local failed=false

  [[ -s "$workloads_file" ]] || {
    log "no controller-owned workloads to wait for"
    return 0
  }

  log "waiting for displaced workload controllers to settle"

  while IFS=$'\t' read -r namespace workload; do
    [[ -n "$namespace" && -n "$workload" ]] || continue

    case "$workload" in
      deployment/* | statefulset/*)
        log "waiting for ${namespace}/${workload}"
        if ! kubectl -n "$namespace" rollout status "$workload" --timeout="$SETTLE_TIMEOUT"; then
          failed=true
        fi
        ;;
      replicaset/*)
        log "waiting for ${namespace}/${workload} pods to be Ready"
        selector=$(
          kubectl -n "$namespace" get "$workload" -o json | jq -r '
            .spec.selector.matchLabels
            | to_entries
            | map("\(.key)=\(.value)")
            | join(",")'
        )

        if ! kubectl -n "$namespace" wait --for=condition=Ready pod \
          --selector="$selector" \
          --timeout="$SETTLE_TIMEOUT"; then
          failed=true
        fi
        ;;
      *)
        log "cannot generically wait for ${namespace}/${workload}; skipping"
        ;;
    esac
  done <"$workloads_file"

  [[ "$failed" == false ]] || die "one or more displaced workloads did not settle"
}

wait_for_controller_ready_floor() {
  local namespace="$1"
  local workload="$2"
  local minimum_ready="$3"
  local deadline
  local ready

  deadline=$((SECONDS + $(duration_to_seconds "$SETTLE_TIMEOUT")))

  while ((SECONDS < deadline)); do
    ready=$(
      kubectl -n "$namespace" get "$workload" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true
    )
    ready="${ready:-0}"

    if ((ready >= minimum_ready)); then
      return 0
    fi

    sleep "$POLL_SECONDS"
  done

  die "${namespace}/${workload} has ${ready} Ready replicas; maintenance requires ${minimum_ready}"
}

wait_for_displaced_workload_survivability() {
  local workloads_file="$1"
  local namespace
  local workload
  local desired
  local minimum_ready

  [[ -s "$workloads_file" ]] || {
    log "no controller-owned workloads need maintenance checks"
    return 0
  }

  log "checking displaced workload availability"

  while IFS=$'\t' read -r namespace workload; do
    [[ -n "$namespace" && -n "$workload" ]] || continue

    case "$workload" in
      deployment/* | replicaset/*)
        desired=$(
          kubectl -n "$namespace" get "$workload" \
            -o jsonpath='{.spec.replicas}' 2>/dev/null || true
        )
        desired="${desired:-1}"
        wait_for_controller_ready_floor "$namespace" "$workload" "$desired"
        ;;
      statefulset/*)
        desired=$(
          kubectl -n "$namespace" get "$workload" \
            -o jsonpath='{.spec.replicas}' 2>/dev/null || true
        )
        desired="${desired:-1}"
        minimum_ready=1
        if ((desired > 1)); then
          minimum_ready=$((desired - 1))
        fi
        wait_for_controller_ready_floor "$namespace" "$workload" "$minimum_ready"
        ;;
      *)
        log "using a dedicated availability gate for ${namespace}/${workload}"
        ;;
    esac
  done <"$workloads_file"
}

wait_for_no_bad_pods() {
  local deadline
  local settle_seconds
  local bad

  log "checking for unhealthy non-Job pods"
  settle_seconds=$(duration_to_seconds "$SETTLE_TIMEOUT")
  deadline=$((SECONDS + settle_seconds))

  while ((SECONDS < deadline)); do
    bad=$(
      kubectl get pods --all-namespaces -o json | jq -r '
        .items[]
        | select((.metadata.ownerReferences // [] | map(.kind) | index("Job")) | not)
        | select(.status.phase != "Succeeded")
        | select(
            .status.phase == "Failed"
            or (.status.containerStatuses // [] | any(
              .state.waiting.reason as $reason
              | ["CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError", "CreateContainerError"] | index($reason)
            ))
          )
        | "\(.metadata.namespace)/\(.metadata.name): \(.status.phase)"'
    )

    if [[ -z "$bad" ]]; then
      return 0
    fi

    printf '%s\n' "$bad" >&2
    sleep "$POLL_SECONDS"
  done

  die "unhealthy pods remained after waiting"
}

verify_node_is_cordoned() {
  local unschedulable

  unschedulable=$(kubectl get node "$NODE" -o jsonpath='{.spec.unschedulable}')
  [[ "$unschedulable" == "true" ]] ||
    die "${NODE} is not cordoned; --resume-maintenance requires an existing maintenance cordon"
}

verify_node_has_only_maintenance_pods() {
  local bad_pods

  bad_pods=$(
    kubectl get pods --all-namespaces \
      --field-selector "spec.nodeName=${NODE}" \
      -o json | jq -r '
        .items[]
        | select(.status.phase != "Succeeded" and .status.phase != "Failed")
        | select(
            (.metadata.ownerReferences[0].kind // "") != "DaemonSet"
            and ((
              .metadata.namespace == "longhorn-system"
              and .metadata.labels["longhorn.io/component"] == "instance-manager"
            ) | not)
          )
        | "\(.metadata.namespace)/\(.metadata.name)\towner=\(.metadata.ownerReferences[0].kind // "none")\tphase=\(.status.phase)"'
  )

  if [[ -n "$bad_pods" ]]; then
    printf '%s\n' "$bad_pods" >&2
    die "non-maintenance Pods remain on ${NODE}"
  fi
}

wait_for_cloudnativepg_survivability() {
  local deadline
  local bad_clusters=""

  if ! kubectl get clusters.postgresql.cnpg.io --all-namespaces >/dev/null 2>&1; then
    log "CloudNativePG clusters not found; skipping database maintenance gate"
    return 0
  fi

  log "checking CloudNativePG one-node-down availability"
  deadline=$((SECONDS + $(duration_to_seconds "$SETTLE_TIMEOUT")))

  while ((SECONDS < deadline)); do
    bad_clusters=$(
      kubectl get clusters.postgresql.cnpg.io --all-namespaces -o json | jq -r \
        --arg node "$NODE" \
        --slurpfile pods <(kubectl get pods --all-namespaces -o json) '
          ($pods[0].items
            | map({key: (.metadata.namespace + "/" + .metadata.name), value: .})
            | from_entries) as $pod_index
          | .items[]
          | (.spec.instances // 1) as $desired
          | (if $desired > 1 then $desired - 1 else 1 end) as $minimum_ready
          | (.status.readyInstances // 0) as $ready
          | (.status.currentPrimary // "") as $primary
          | ($pod_index[.metadata.namespace + "/" + $primary] // {}) as $primary_pod
          | select(
              $ready < $minimum_ready
              or $primary == ""
              or ($primary_pod.metadata.name // "") != $primary
              or ($primary_pod.spec.nodeName // "") == $node
              or ($primary_pod.status.phase // "") != "Running"
              or ($primary_pod.status.containerStatuses // [] | length) == 0
              or ($primary_pod.status.containerStatuses // [] | any(.ready != true))
            )
          | "\(.metadata.namespace)/\(.metadata.name)\tready=\($ready)/\($desired)\tminimum=\($minimum_ready)\tprimary=\($primary)\tprimaryNode=\($primary_pod.spec.nodeName // "missing")"'
    )

    [[ -n "$bad_clusters" ]] || return 0
    printf '%s\n' "$bad_clusters" >&2
    sleep "$POLL_SECONDS"
  done

  die "CloudNativePG maintenance availability gate did not pass"
}

wait_for_cloudnativepg_health() {
  local deadline
  local bad_clusters=""

  if ! kubectl get clusters.postgresql.cnpg.io --all-namespaces >/dev/null 2>&1; then
    return 0
  fi

  log "waiting for CloudNativePG clusters to become fully healthy"
  deadline=$((SECONDS + $(duration_to_seconds "$SETTLE_TIMEOUT")))

  while ((SECONDS < deadline)); do
    bad_clusters=$(
      kubectl get clusters.postgresql.cnpg.io --all-namespaces -o json | jq -r '
        .items[]
        | (.spec.instances // 1) as $desired
        | (.status.readyInstances // 0) as $ready
        | select($ready != $desired or .status.phase != "Cluster in healthy state")
        | "\(.metadata.namespace)/\(.metadata.name)\tready=\($ready)/\($desired)\tphase=\(.status.phase // "unknown")"'
    )

    [[ -n "$bad_clusters" ]] || return 0
    printf '%s\n' "$bad_clusters" >&2
    sleep "$POLL_SECONDS"
  done

  die "CloudNativePG clusters did not return to full health"
}

wait_for_longhorn_health() {
  local deadline
  local settle_seconds
  local bad_volumes
  local backup_available
  local backup_reason
  local under_replicated

  if ! kubectl get namespace longhorn-system >/dev/null 2>&1; then
    log "longhorn-system namespace not found; skipping Longhorn checks"
    return 0
  fi

  if ! kubectl -n longhorn-system get volumes.longhorn.io >/dev/null 2>&1; then
    log "Longhorn volume CRDs not found; skipping Longhorn checks"
    return 0
  fi

  log "checking attached Longhorn replica floor (${MIN_LONGHORN_REPLICAS})"
  under_replicated=$(
    kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r \
      --argjson minimum "$MIN_LONGHORN_REPLICAS" '
        .items[]
        | select(.status.state == "attached" or .status.state == "attaching")
        | select((.spec.numberOfReplicas // 0) < $minimum)
        | "\(.metadata.name)\tdesired=\(.spec.numberOfReplicas // 0)\t\(.status.state)\t\(.status.kubernetesStatus.namespace // "")/\(.status.kubernetesStatus.pvcName // "")"'
  )
  if [[ -n "$under_replicated" ]]; then
    printf '%s\n' "$under_replicated" >&2
    die "attached Longhorn volumes are below the replica policy floor"
  fi

  log "waiting for attached Longhorn volumes to be healthy"
  settle_seconds=$(duration_to_seconds "$SETTLE_TIMEOUT")
  deadline=$((SECONDS + settle_seconds))

  while ((SECONDS < deadline)); do
    bad_volumes=$(
      kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r '
        .items[]
        | select(.status.state == "attached" or .status.state == "attaching")
        | select(.status.robustness != "healthy")
        | "\(.metadata.name)\t\(.status.state)\t\(.status.robustness)\t\(.status.kubernetesStatus.namespace // "")/\(.status.kubernetesStatus.pvcName // "")"'
    )

    if [[ -z "$bad_volumes" ]]; then
      break
    fi

    printf '%s\n' "$bad_volumes" >&2
    sleep "$POLL_SECONDS"
  done

  [[ -z "$bad_volumes" ]] || die "Longhorn volumes are not healthy"

  if kubectl -n longhorn-system get backuptargets.longhorn.io default >/dev/null 2>&1; then
    log "checking Longhorn backup target"
    backup_available=$(
      kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.available}' 2>/dev/null || true
    )

    if [[ "$backup_available" != "true" ]]; then
      backup_reason=$(
        kubectl -n longhorn-system get backuptargets.longhorn.io default -o json | jq -r '
          (.status.conditions // [])
          | map(select(.type == "Unavailable" and .status == "True"))
          | .[0].reason // "unavailable"'
      )

      if [[ "$REQUIRE_LONGHORN_BACKUP_TARGET" == true ]]; then
        die "Longhorn backup target is not available (${backup_reason})"
      fi

      log "Longhorn backup target is not available (${backup_reason}); continuing"
    fi
  fi
}

check_pdb_eviction_blockers() {
  local report

  log "checking PodDisruptionBudgets on ${NODE}"
  report=$(
    kubectl get poddisruptionbudgets.policy --all-namespaces -o json |
      jq -r --arg node "$NODE" --slurpfile pods <(kubectl get pods --all-namespaces -o json) '
        def selector_matches($labels; $selector):
          (($selector.matchLabels // {}) | to_entries | all(
            . as $entry | ($labels[$entry.key] // null) == $entry.value
          ))
          and
          (($selector.matchExpressions // []) | all(
            . as $expression
            | ($labels[$expression.key] // null) as $value
            | if $expression.operator == "In" then
                $value != null and (($expression.values // []) | index($value) != null)
              elif $expression.operator == "NotIn" then
                $value != null and (($expression.values // []) | index($value) == null)
              elif $expression.operator == "Exists" then
                $labels | has($expression.key)
              elif $expression.operator == "DoesNotExist" then
                ($labels | has($expression.key)) | not
              else
                false
              end
          ));

        .items[] as $pdb
        | select(($pdb.status.disruptionsAllowed // 0) < 1)
        | $pods[0].items[]
        | select(.spec.nodeName == $node)
        | select(.status.phase != "Succeeded" and .status.phase != "Failed")
        | select((.metadata.ownerReferences // [] | map(.kind) | index("DaemonSet")) | not)
        | select((.metadata.labels["longhorn.io/component"] // "") != "instance-manager")
        | select(selector_matches(.metadata.labels // {}; $pdb.spec.selector // {}))
        | [
            .metadata.namespace,
            $pdb.metadata.name,
            .metadata.name,
            ((.metadata.labels["cnpg.io/instanceRole"] // "-") | tostring)
          ]
        | @tsv'
  )

  if [[ -n "$report" ]]; then
    printf 'namespace\tpdb\tpod\tinstance-role\n%s\n' "$report" >&2
    die "PodDisruptionBudgets block eviction; restore replicas or switchover primaries before disrupting ${NODE}"
  fi
}

check_stable_node_pod_slots() {
  local report
  local status

  log "checking remaining stable-node aggregate Pod capacity (${MIN_FREE_POD_SLOTS} slots reserved)"
  report=$(
    kubectl get nodes -l workload-class=stable -o json |
      jq -r \
        --arg target "$NODE" \
        --argjson required "$MIN_FREE_POD_SLOTS" \
        --slurpfile pods <(kubectl get pods --all-namespaces -o json) '
          def active_pod:
            .status.phase != "Succeeded" and .status.phase != "Failed";
          def daemonset_pod:
            (.metadata.ownerReferences // [] | map(.kind) | index("DaemonSet")) != null;
          def mirror_pod:
            (.metadata.annotations["kubernetes.io/config.mirror"] // "") != "";

          [
            .items[]
            | select(.metadata.name != $target)
            | select(.spec.unschedulable != true)
            | select(.status.conditions | any(.type == "Ready" and .status == "True"))
          ] as $remaining
          | ($remaining | map(.metadata.name)) as $remaining_names
          | ($remaining | map(.status.allocatable.pods | tonumber) | add // 0) as $allocatable
          | ([
              $pods[0].items[]
              | select(active_pod)
              | select(.spec.nodeName as $node | $remaining_names | index($node) != null)
            ] | length) as $scheduled
          | ([
              $pods[0].items[]
              | select(active_pod)
              | select(.spec.nodeName == $target)
              | select(daemonset_pod | not)
              | select(mirror_pod | not)
            ] | length) as $displaced
          | ($allocatable - $scheduled - $displaced) as $free_after
          | [
              ($remaining_names | join(",")),
              ($scheduled | tostring),
              ($displaced | tostring),
              ($allocatable | tostring),
              ($free_after | tostring),
              (if ($remaining | length) > 0 and $free_after >= $required then "pass" else "insufficient" end)
            ]
          | @tsv'
  )

  [[ -n "$report" ]] || die "no remaining stable nodes found for Pod capacity audit"
  printf 'remaining-nodes\tscheduled\tdisplaced\tallocatable\tfree-after\tstatus\n%s\n' "$report"

  status=$(awk -F '\t' '{ print $6 }' <<<"$report")
  [[ "$status" == "pass" ]] || die "remaining stable nodes do not have enough aggregate Pod slots"
}

wait_for_longhorn_survivability() {
  local deadline
  local bad_volumes=""

  if ! kubectl -n longhorn-system get volumes.longhorn.io >/dev/null 2>&1; then
    return 0
  fi

  log "checking Longhorn one-node-down replica floor (${MIN_SURVIVING_LONGHORN_REPLICAS})"
  deadline=$((SECONDS + $(duration_to_seconds "$SETTLE_TIMEOUT")))

  while ((SECONDS < deadline)); do
    bad_volumes=$(
      kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r \
        --arg node "$NODE" \
        --argjson minimum "$MIN_SURVIVING_LONGHORN_REPLICAS" \
        --slurpfile replicas <(kubectl -n longhorn-system get replicas.longhorn.io -o json) '
          ($replicas[0].items
            | group_by(.spec.volumeName)
            | map({key: .[0].spec.volumeName, value: .})
            | from_entries) as $replica_index
          | .items[]
          | select(.status.state == "attached" or .status.state == "attaching")
          | . as $volume
          | ([
              ($replica_index[.metadata.name] // [])[]
              | select(
                  .spec.nodeID != $node
                  and .status.currentState == "running"
                  and (.spec.failedAt // "") == ""
                )
              | .spec.nodeID
            ] | unique) as $surviving_nodes
          | select(
              (.spec.numberOfReplicas // 0) < 3
              or .status.state != "attached"
              or .status.robustness == "faulted"
              or (.status.currentNodeID // "") == $node
              or (.spec.nodeID // "") == $node
              or ($surviving_nodes | length) < $minimum
            )
          | "\(.metadata.name)\t\(.status.kubernetesStatus.namespace // "")/\(.status.kubernetesStatus.pvcName // "")\tstate=\(.status.state)\trobustness=\(.status.robustness)\tattachment=\(.status.currentNodeID // "")\tsurvivingNodes=\($surviving_nodes | join(","))"'
    )

    [[ -n "$bad_volumes" ]] || return 0
    printf '%s\n' "$bad_volumes" >&2
    sleep "$POLL_SECONDS"
  done

  die "Longhorn one-node-down availability gate did not pass"
}

wait_for_node_storage_detach() {
  local deadline
  local timeout_seconds
  local attached_volumes=""

  if kubectl -n longhorn-system get volumes.longhorn.io >/dev/null 2>&1; then
    log "waiting for Longhorn volumes to detach from ${NODE}"
    timeout_seconds=$(duration_to_seconds "$DRAIN_TIMEOUT")
    deadline=$((SECONDS + timeout_seconds))

    while ((SECONDS < deadline)); do
      attached_volumes=$(
        kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r --arg node "$NODE" '
          .items[]
          | select(.status.currentNodeID == $node or .spec.nodeID == $node)
          | select(.status.state != "detached")
          | "\(.metadata.name)\t\(.status.state)\t\(.status.kubernetesStatus.namespace // \"\")/\(.status.kubernetesStatus.pvcName // \"\")"'
      )

      [[ -n "$attached_volumes" ]] || break
      printf '%s\n' "$attached_volumes" >&2
      sleep "$POLL_SECONDS"
    done

    [[ -z "$attached_volumes" ]] || die "Longhorn volumes remain attached to ${NODE}"
  fi

  log "checking ${SSH_TARGET} for residual Longhorn mounts and iSCSI sessions"
  if ! ssh -o BatchMode=yes "$SSH_TARGET" 'sudo bash -s' <<'EOF'; then
set -euo pipefail

command -v findmnt >/dev/null
command -v iscsiadm >/dev/null

mounts=$(
  findmnt -rn -o TARGET \
    | grep -E '^/var/lib/kubelet/plugins/kubernetes.io/csi/driver\.longhorn\.io/.+/globalmount$' \
    || true
)
sessions=$(iscsiadm -m session 2>/dev/null | grep -F 'io.longhorn' || true)

if [[ -n "$mounts" || -n "$sessions" ]]; then
  [[ -z "$mounts" ]] || printf 'Residual Longhorn mounts:\n%s\n' "$mounts" >&2
  [[ -z "$sessions" ]] || printf 'Residual Longhorn iSCSI sessions:\n%s\n' "$sessions" >&2
  exit 1
fi
EOF
    die "residual Longhorn storage is still active on ${SSH_TARGET}"
  fi
}

warn_for_longhorn_health() {
  local bad_volumes

  if ! kubectl get namespace longhorn-system >/dev/null 2>&1; then
    return 0
  fi

  if ! kubectl -n longhorn-system get volumes.longhorn.io >/dev/null 2>&1; then
    return 0
  fi

  bad_volumes=$(
    kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r '
      .items[]
      | select(.status.state == "attached" or .status.state == "attaching")
      | select(.status.robustness != "healthy")
      | "\(.metadata.name)\t\(.status.state)\t\(.status.robustness)\t\(.status.kubernetesStatus.namespace // "")/\(.status.kubernetesStatus.pvcName // "")"'
  )

  if [[ -n "$bad_volumes" ]]; then
    log "attached Longhorn volumes are not healthy after drain; continuing for poweroff"
    printf '%s\n' "$bad_volumes" >&2
  fi
}

settle_cluster() {
  local workloads_file="$1"

  wait_for_workloads "$workloads_file"
  if [[ "$ACTION" == "off" ]]; then
    warn_for_longhorn_health
  else
    wait_for_longhorn_health
  fi
  wait_for_cloudnativepg_health
  wait_for_no_bad_pods
}

verify_returned_node_network() {
  local internal_ip
  local flannel_ip

  internal_ip=$(
    kubectl get node "$NODE" \
      -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
  )
  flannel_ip=$(
    kubectl get node "$NODE" \
      -o jsonpath='{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip}'
  )

  [[ -n "$internal_ip" ]] || die "${NODE} has no Kubernetes InternalIP"
  [[ "$flannel_ip" == "$internal_ip" ]] ||
    die "${NODE} Flannel public IP (${flannel_ip:-missing}) does not match InternalIP (${internal_ip})"
}

verify_resumed_maintenance_state() {
  log "validating resumed maintenance state for ${NODE}"
  verify_node_is_cordoned
  verify_node_has_only_maintenance_pods
  wait_for_node_storage_detach
  wait_for_longhorn_survivability
  wait_for_cloudnativepg_survivability
  wait_for_no_bad_pods
}

wait_for_ssh_down() {
  log "waiting for SSH on ${SSH_TARGET} to drop"

  for _ in {1..30}; do
    if ! ssh -o BatchMode=yes -o ConnectTimeout=2 "$SSH_TARGET" true >/dev/null 2>&1; then
      return 0
    fi
    sleep "$POLL_SECONDS"
  done

  die "SSH did not drop; the power action was not verified and ${NODE} remains cordoned"
}

wait_for_ssh_up() {
  local elapsed=0

  log "waiting for SSH on ${SSH_TARGET} to return"

  while ((elapsed < SSH_TIMEOUT_SECONDS)); do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_TARGET" true >/dev/null 2>&1; then
      return 0
    fi

    sleep "$POLL_SECONDS"
    elapsed=$((elapsed + POLL_SECONDS))
  done

  die "SSH did not return within ${SSH_TIMEOUT_SECONDS}s"
}

reboot_host() {
  local status

  REMOTE_BOOT_ID=$(ssh -o BatchMode=yes "$SSH_TARGET" cat /proc/sys/kernel/random/boot_id)
  [[ -n "$REMOTE_BOOT_ID" ]] || die "could not read the current boot ID from ${SSH_TARGET}"

  log "rebooting ${SSH_TARGET}"

  set +e
  ssh -t "$SSH_TARGET" 'sudo systemctl reboot --no-block'
  status=$?
  set -e

  case "$status" in
    0 | 255)
      ;;
    *)
      die "remote reboot command failed before reboot started; ${NODE} remains cordoned"
      ;;
  esac
}

verify_new_boot() {
  local current_boot_id

  current_boot_id=$(ssh -o BatchMode=yes "$SSH_TARGET" cat /proc/sys/kernel/random/boot_id)
  [[ -n "$current_boot_id" ]] || die "could not read the boot ID after ${SSH_TARGET} returned"
  [[ "$current_boot_id" != "$REMOTE_BOOT_ID" ]] ||
    die "${SSH_TARGET} returned without rebooting; ${NODE} remains cordoned"
}

poweroff_host() {
  local status

  log "powering off ${SSH_TARGET}"

  set +e
  ssh -t "$SSH_TARGET" 'sudo systemctl poweroff'
  status=$?
  set -e

  case "$status" in
    0 | 255)
      ;;
    *)
      die "remote poweroff command failed before shutdown started"
      ;;
  esac
}

prepare_node_for_disruption() {
  local workloads_file
  local unschedulable
  workloads_file="$1"

  log "checking Kubernetes node ${NODE}"
  kubectl get node "$NODE" >/dev/null

  if [[ "$RESUME_MAINTENANCE" == true ]]; then
    verify_resumed_maintenance_state
    return 0
  fi

  unschedulable=$(kubectl get node "$NODE" -o jsonpath='{.spec.unschedulable}')
  [[ "$unschedulable" != "true" ]] ||
    die "${NODE} is already cordoned; use --resume-maintenance for another power cycle"

  log "running preflight cluster health checks"
  wait_for_longhorn_health
  wait_for_cloudnativepg_health
  wait_for_no_bad_pods
  check_pdb_eviction_blockers
  check_stable_node_pod_slots

  collect_displaced_workloads >"$workloads_file"

  log "cordoning ${NODE}"
  kubectl cordon "$NODE"

  if [[ "$SKIP_DRAIN" == true ]]; then
    log "skipping drain by request"
  else
    local -a drain_args=(
      drain "$NODE"
      --ignore-daemonsets
      --delete-emptydir-data
      '--pod-selector=longhorn.io/component!=instance-manager'
      --timeout="$DRAIN_TIMEOUT"
    )

    if [[ "$FORCE_DRAIN" == true ]]; then
      drain_args+=(--force)
    fi

    if [[ "$BYPASS_PDB" == true ]]; then
      drain_args+=(--disable-eviction)
    fi

    log "draining ${NODE}"
    if ! kubectl "${drain_args[@]}"; then
      die "drain failed; node disruption was not started and ${NODE} remains cordoned"
    fi

    wait_for_displaced_workload_survivability "$workloads_file"
    wait_for_no_bad_pods
  fi

  wait_for_node_storage_detach
  wait_for_longhorn_survivability
  wait_for_cloudnativepg_survivability
}

run_reboot() {
  WORKLOADS_FILE=$(mktemp)
  trap cleanup_workloads_file EXIT

  prepare_node_for_disruption "$WORKLOADS_FILE"
  reboot_host
  wait_for_ssh_down
  wait_for_ssh_up
  verify_new_boot

  log "waiting for ${NODE} to report Ready"
  kubectl wait "node/${NODE}" --for=condition=Ready --timeout="$READY_TIMEOUT"
  verify_returned_node_network
  wait_for_longhorn_survivability
  wait_for_cloudnativepg_survivability

  if [[ "$LEAVE_CORDONED" == true ]]; then
    log "leaving ${NODE} cordoned"
  else
    log "uncordoning ${NODE}"
    kubectl uncordon "$NODE"
    settle_cluster "$WORKLOADS_FILE"
  fi

  log "done"
}

run_poweroff() {
  WORKLOADS_FILE=$(mktemp)
  trap cleanup_workloads_file EXIT

  prepare_node_for_disruption "$WORKLOADS_FILE"
  poweroff_host
  wait_for_ssh_down

  log "${NODE} is powered off and remains cordoned"
}

run_poweron_finalize() {
  log "checking Kubernetes node ${NODE}"
  kubectl get node "$NODE" >/dev/null

  wait_for_ssh_up

  log "waiting for ${NODE} to report Ready"
  kubectl wait "node/${NODE}" --for=condition=Ready --timeout="$READY_TIMEOUT"
  verify_node_is_cordoned
  verify_returned_node_network
  wait_for_longhorn_survivability
  wait_for_cloudnativepg_survivability

  log "uncordoning ${NODE}"
  kubectl uncordon "$NODE"

  wait_for_longhorn_health
  wait_for_cloudnativepg_health
  wait_for_no_bad_pods

  log "done"
}

run_check_only() {
  local unschedulable

  log "checking Kubernetes node ${NODE} without changing cluster or host state"
  kubectl get node "$NODE" >/dev/null

  if [[ "$RESUME_MAINTENANCE" == true ]]; then
    verify_resumed_maintenance_state
  else
    unschedulable=$(kubectl get node "$NODE" -o jsonpath='{.spec.unschedulable}')
    [[ "$unschedulable" != "true" ]] ||
      die "${NODE} is already cordoned; use --resume-maintenance for maintenance-state checks"
    wait_for_longhorn_health
    wait_for_cloudnativepg_health
    wait_for_no_bad_pods
    check_pdb_eviction_blockers
    check_stable_node_pod_slots
  fi

  log "checks passed; no changes were made"
}

main() {
  parse_args "$@"
  need_command kubectl
  need_command ssh
  need_command jq
  need_command awk

  if [[ "$RESUME_MAINTENANCE" == true && "$ACTION" == "on" ]]; then
    die "--resume-maintenance is for reboot/off cycles; use kon to finalize maintenance"
  fi

  if [[ "$RESUME_MAINTENANCE" == true && "$SKIP_DRAIN" == true ]]; then
    die "--resume-maintenance and --skip-drain cannot be combined"
  fi

  if [[ "$CHECK_ONLY" == true ]]; then
    run_check_only
    return 0
  fi

  case "$ACTION" in
    reboot)
      run_reboot
      ;;
    off)
      run_poweroff
      ;;
    on)
      run_poweron_finalize
      ;;
    *)
      die "unsupported action: ${ACTION}"
      ;;
  esac
}

main "$@"
