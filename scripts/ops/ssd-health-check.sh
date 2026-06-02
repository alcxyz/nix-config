#!/usr/bin/env bash
set -euo pipefail

DEVICE=""
START_LONG=false
WAIT_LONG=false
READ_SCAN=false
POLL_SECONDS=60
REPORT_DIR="/tmp"

usage() {
  cat <<'EOF'
Usage: ssd-health-check [options] <device>

Run non-destructive SSD health checks.

Options:
  --start-long          Start the SMART long self-test.
  --wait-long           Poll SMART until the current self-test finishes.
  --read-scan           Run a read-only badblocks scan after SMART reporting.
  --poll-seconds <n>    Poll interval for --wait-long. Default: 60.
  --report-dir <path>   Directory for the report log. Default: /tmp.
  -h, --help            Show this help.

Examples:
  sudo scripts/ops/ssd-health-check.sh /dev/sdd
  sudo scripts/ops/ssd-health-check.sh --start-long /dev/sdd
  sudo scripts/ops/ssd-health-check.sh --wait-long --read-scan /dev/sdd

Notes:
  - SMART checks require root on most systems.
  - --read-scan is read-only, but it can take hours on large disks.
  - This script never runs destructive write tests.
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
      --start-long)
        START_LONG=true
        shift
        ;;
      --wait-long)
        WAIT_LONG=true
        shift
        ;;
      --read-scan)
        READ_SCAN=true
        shift
        ;;
      --poll-seconds)
        [[ $# -ge 2 ]] || die "--poll-seconds requires a value"
        POLL_SECONDS="$2"
        shift 2
        ;;
      --report-dir)
        [[ $# -ge 2 ]] || die "--report-dir requires a value"
        REPORT_DIR="$2"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        [[ -z "$DEVICE" ]] || die "only one device may be provided"
        DEVICE="$1"
        shift
        ;;
    esac
  done

  [[ -n "$DEVICE" ]] || die "device is required"
  [[ "$POLL_SECONDS" =~ ^[0-9]+$ ]] || die "--poll-seconds must be an integer"
  [[ "$POLL_SECONDS" -gt 0 ]] || die "--poll-seconds must be greater than zero"
  [[ -b "$DEVICE" ]] || die "not a block device: $DEVICE"
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "run as root so smartctl can access $DEVICE"
  fi
}

open_report() {
  local device_name
  local stamp

  mkdir -p "$REPORT_DIR"
  device_name="$(basename "$DEVICE")"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  REPORT_PATH="${REPORT_DIR}/ssd-health-${device_name}-${stamp}.log"
  exec > >(tee "$REPORT_PATH") 2>&1
}

print_device_context() {
  log "device context"
  lsblk -o NAME,PATH,MODEL,SERIAL,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$DEVICE"
  printf '\n'
}

print_smart_report() {
  log "SMART identity"
  smartctl -i "$DEVICE"
  printf '\n'

  log "SMART health"
  smartctl -H "$DEVICE"
  printf '\n'

  log "SMART full report"
  smartctl -a "$DEVICE"
  printf '\n'
}

start_long_test() {
  log "starting SMART long self-test"
  smartctl -t long "$DEVICE"
  printf '\n'
}

self_test_in_progress() {
  smartctl -c "$DEVICE" | grep -qi "Self-test routine in progress"
}

wait_for_long_test() {
  log "waiting for SMART self-test to finish"
  while self_test_in_progress; do
    smartctl -c "$DEVICE" | sed -n '/Self-test execution status/,+2p'
    sleep "$POLL_SECONDS"
  done

  log "SMART self-test log"
  smartctl -l selftest "$DEVICE"
  printf '\n'
}

read_scan() {
  log "starting read-only badblocks scan"
  badblocks -b 4096 -sv "$DEVICE"
  printf '\n'
}

main() {
  parse_args "$@"
  need_command smartctl
  need_command lsblk
  if [[ "$READ_SCAN" == true ]]; then
    need_command badblocks
  fi
  require_root
  open_report

  log "writing report to $REPORT_PATH"
  print_device_context
  print_smart_report

  if [[ "$START_LONG" == true ]]; then
    start_long_test
  fi
  if [[ "$WAIT_LONG" == true ]]; then
    wait_for_long_test
  fi
  if [[ "$READ_SCAN" == true ]]; then
    read_scan
  fi

  log "done"
}

main "$@"
