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
DRAIN_TIMEOUT="10m"
READY_TIMEOUT="10m"
SETTLE_TIMEOUT="15m"
SSH_TIMEOUT_SECONDS=900
POLL_SECONDS=5
REQUIRE_LONGHORN_BACKUP_TARGET=false
MIN_FREE_POD_SLOTS=20
REMOTE_BOOT_ID=""

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
  --drain-timeout <dur>    kubectl drain duration. Default: 10m.
  --ready-timeout <dur>    kubectl wait duration. Default: 10m.
  --settle-timeout <dur>   Workload/Longhorn health wait duration. Default: 15m.
  --ssh-timeout <seconds>  SSH return timeout. Default: 900.
  --require-longhorn-backup-target
                           Fail if the Longhorn backup target is unavailable.
  --min-free-pod-slots N   Require N unused Pod slots on every stable node.
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

wait_for_longhorn_health() {
  local deadline
  local settle_seconds
  local bad_volumes
  local backup_available
  local backup_reason

  if ! kubectl get namespace longhorn-system >/dev/null 2>&1; then
    log "longhorn-system namespace not found; skipping Longhorn checks"
    return 0
  fi

  if ! kubectl -n longhorn-system get volumes.longhorn.io >/dev/null 2>&1; then
    log "Longhorn volume CRDs not found; skipping Longhorn checks"
    return 0
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

check_stable_node_pod_slots() {
  local report

  log "checking stable-node Pod slot floor (${MIN_FREE_POD_SLOTS})"
  report=$(
    kubectl get nodes -l workload-class=stable -o json \
      | jq -r --argjson required "$MIN_FREE_POD_SLOTS" --slurpfile pods <(kubectl get pods --all-namespaces -o json) '
          .items[] as $node
          | ([
              $pods[0].items[]
              | select(
                  .spec.nodeName == $node.metadata.name
                  and .status.phase != "Succeeded"
                  and .status.phase != "Failed"
                )
            ] | length) as $scheduled
          | ($node.status.allocatable.pods | tonumber) as $allocatable
          | ($allocatable - $scheduled) as $free
          | [
              $node.metadata.name,
              ($scheduled | tostring),
              ($allocatable | tostring),
              ($free | tostring),
              (if $free >= $required then "pass" else "insufficient" end)
            ]
          | @tsv'
  )

  [[ -n "$report" ]] || die "no stable nodes found for Pod slot audit"
  printf 'node\tscheduled\tallocatable\tfree\tstatus\n%s\n' "$report"

  if awk -F '\t' '$5 != "pass" { found=1 } END { exit !found }' <<<"$report"; then
    die "one or more stable nodes are below the Pod slot floor"
  fi
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
      kubectl uncordon "$NODE" || true
      die "remote reboot command failed before reboot started"
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
  workloads_file="$1"

  log "checking Kubernetes node ${NODE}"
  kubectl get node "$NODE" >/dev/null

  log "running preflight cluster health checks"
  wait_for_longhorn_health
  wait_for_no_bad_pods
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
      log "drain failed; uncordoning ${NODE}"
      kubectl uncordon "$NODE" || true
      die "drain failed; node disruption was not started"
    fi

    settle_cluster "$workloads_file"
  fi

  wait_for_node_storage_detach
}

run_reboot() {
  local workloads_file
  workloads_file=$(mktemp)
  trap 'rm -f "$workloads_file"' EXIT

  prepare_node_for_disruption "$workloads_file"
  reboot_host
  wait_for_ssh_down
  wait_for_ssh_up
  verify_new_boot

  log "waiting for ${NODE} to report Ready"
  kubectl wait "node/${NODE}" --for=condition=Ready --timeout="$READY_TIMEOUT"

  if [[ "$LEAVE_CORDONED" == true ]]; then
    log "leaving ${NODE} cordoned"
  else
    log "uncordoning ${NODE}"
    kubectl uncordon "$NODE"
    settle_cluster "$workloads_file"
  fi

  log "done"
}

run_poweroff() {
  local workloads_file
  workloads_file=$(mktemp)
  trap 'rm -f "$workloads_file"' EXIT

  prepare_node_for_disruption "$workloads_file"
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

  log "uncordoning ${NODE}"
  kubectl uncordon "$NODE"

  wait_for_longhorn_health
  wait_for_no_bad_pods

  log "done"
}

main() {
  parse_args "$@"
  need_command kubectl
  need_command ssh
  need_command jq
  need_command awk

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
