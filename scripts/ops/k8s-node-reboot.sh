#!/usr/bin/env bash
set -euo pipefail

HOST=""
NODE=""
SSH_TARGET=""
SKIP_DRAIN=false
FORCE_DRAIN=false
LEAVE_CORDONED=false
READY_TIMEOUT="10m"
SSH_TIMEOUT_SECONDS=900
POLL_SECONDS=5

usage() {
  cat <<'EOF'
Usage: k8s-node-reboot [options] <host>

Cordon, drain, reboot, wait for Ready, then uncordon a Kubernetes node.

Options:
  --node <name>            Kubernetes node name. Defaults to <host>.
  --ssh-target <target>    SSH target. Defaults to <host>.
  --skip-drain             Cordon only, then reboot. Use for intentional disruption.
  --force-drain            Pass --force to kubectl drain for unmanaged pods.
  --leave-cordoned         Keep the node cordoned after it returns.
  --ready-timeout <dur>    kubectl wait duration. Default: 10m.
  --ssh-timeout <seconds>  SSH return timeout. Default: 900.
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
      --leave-cordoned)
        LEAVE_CORDONED=true
        shift
        ;;
      --ready-timeout)
        [[ $# -ge 2 ]] || die "--ready-timeout requires a value"
        READY_TIMEOUT="$2"
        shift 2
        ;;
      --ssh-timeout)
        [[ $# -ge 2 ]] || die "--ssh-timeout requires a value"
        SSH_TIMEOUT_SECONDS="$2"
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
}

wait_for_ssh_down() {
  log "waiting for SSH on ${SSH_TARGET} to drop"

  for _ in {1..30}; do
    if ! ssh -o BatchMode=yes -o ConnectTimeout=2 "$SSH_TARGET" true >/dev/null 2>&1; then
      return 0
    fi
    sleep "$POLL_SECONDS"
  done

  log "SSH did not drop; continuing to wait for it to become available"
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

  log "rebooting ${SSH_TARGET}"

  set +e
  ssh -t "$SSH_TARGET" 'sudo systemctl reboot'
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

main() {
  parse_args "$@"
  need_command kubectl
  need_command ssh

  log "checking Kubernetes node ${NODE}"
  kubectl get node "$NODE" >/dev/null

  log "cordoning ${NODE}"
  kubectl cordon "$NODE"

  if [[ "$SKIP_DRAIN" == true ]]; then
    log "skipping drain by request"
  else
    local -a drain_args=(
      drain "$NODE"
      --ignore-daemonsets
      --delete-emptydir-data
    )

    if [[ "$FORCE_DRAIN" == true ]]; then
      drain_args+=(--force)
    fi

    log "draining ${NODE}"
    if ! kubectl "${drain_args[@]}"; then
      log "drain failed; uncordoning ${NODE}"
      kubectl uncordon "$NODE" || true
      die "drain failed; reboot was not started"
    fi
  fi

  reboot_host
  wait_for_ssh_down
  wait_for_ssh_up

  log "waiting for ${NODE} to report Ready"
  kubectl wait "node/${NODE}" --for=condition=Ready --timeout="$READY_TIMEOUT"

  if [[ "$LEAVE_CORDONED" == true ]]; then
    log "leaving ${NODE} cordoned"
  else
    log "uncordoning ${NODE}"
    kubectl uncordon "$NODE"
  fi

  log "done"
}

main "$@"
