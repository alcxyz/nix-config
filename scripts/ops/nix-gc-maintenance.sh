#!/usr/bin/env bash
set -euo pipefail

KEEP_GENERATIONS=10
MAX_FREED_BYTES=10737418240
PROFILE_ROOT="${NIX_GC_PROFILE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles}"
SYSTEM_PROFILE="${NIX_GC_SYSTEM_PROFILE:-/nix/var/nix/profiles/system}"
NIX_ENV_BIN="${NIX_ENV_BIN:-nix-env}"
NIX_STORE_BIN="${NIX_STORE_BIN:-nix-store}"
SUDO_BIN="${SUDO_BIN:-sudo}"
SSH_BIN="${SSH_BIN:-ssh}"
SCRIPT_SOURCE="${NIX_GC_SCRIPT_SOURCE:-${BASH_SOURCE[0]}}"

usage() {
  cat <<'EOF'
Usage: nix-gc-maintenance [host]

Retain 10 generations in the current user's Home Manager/user profiles and
the system profile, then garbage-collect up to 10 GiB.

With a host argument, stream this maintenance command to that host over SSH.
The managed SSH host must log in as a non-root user with sudo access.
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

profile_exists() {
  [[ -e "$1" || -L "$1" ]]
}

delete_user_generations() {
  local name profile

  for name in home-manager profile; do
    profile="$PROFILE_ROOT/$name"
    if profile_exists "$profile"; then
      log "retaining the latest ${KEEP_GENERATIONS} generations in $profile"
      "$NIX_ENV_BIN" \
        --profile "$profile" \
        --delete-generations "+${KEEP_GENERATIONS}"
    fi
  done
}

run_privileged() {
  "$SUDO_BIN" "$@"
}

run_remote() {
  local host="$1"

  [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    die "invalid SSH host: $host"
  [[ -r "$SCRIPT_SOURCE" ]] || die "maintenance script is not readable: $SCRIPT_SOURCE"

  need_command "$SSH_BIN"
  SSH_BIN=$(command -v "$SSH_BIN")
  log "running Nix GC maintenance on $host"
  exec "$SSH_BIN" -tt "$host" bash -s <"$SCRIPT_SOURCE"
}

main() {
  if [[ $# -gt 1 ]]; then
    usage >&2
    exit 2
  fi
  if [[ $# -eq 1 ]]; then
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      *)
        run_remote "$1"
        ;;
    esac
  fi

  [[ "$(id -u)" -ne 0 ]] ||
    die "run as the managed user; this command requests sudo for system maintenance"

  need_command "$NIX_ENV_BIN"
  need_command "$NIX_STORE_BIN"
  need_command "$SUDO_BIN"
  NIX_ENV_BIN=$(command -v "$NIX_ENV_BIN")
  NIX_STORE_BIN=$(command -v "$NIX_STORE_BIN")
  SUDO_BIN=$(command -v "$SUDO_BIN")

  delete_user_generations

  if profile_exists "$SYSTEM_PROFILE"; then
    log "retaining the latest ${KEEP_GENERATIONS} generations in $SYSTEM_PROFILE"
    run_privileged "$NIX_ENV_BIN" \
      --profile "$SYSTEM_PROFILE" \
      --delete-generations "+${KEEP_GENERATIONS}"
  fi

  log "garbage-collecting up to ${MAX_FREED_BYTES} bytes"
  run_privileged "$NIX_STORE_BIN" --gc --max-freed "$MAX_FREED_BYTES"
}

main "$@"
