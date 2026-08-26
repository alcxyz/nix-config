#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MAINTENANCE="$ROOT/scripts/ops/nix-gc-maintenance.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

BIN_DIR="$TEST_ROOT/bin"
PROFILE_ROOT="$TEST_ROOT/profiles"
SYSTEM_PROFILE="$TEST_ROOT/system"
CALL_LOG="$TEST_ROOT/calls.log"

mkdir -p "$BIN_DIR" "$PROFILE_ROOT"
touch "$PROFILE_ROOT/home-manager" "$PROFILE_ROOT/profile" "$SYSTEM_PROFILE"

cat >"$BIN_DIR/nix-env" <<'EOF'
#!/usr/bin/env bash
printf 'nix-env' >>"$CALL_LOG"
printf ' <%s>' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
EOF

cat >"$BIN_DIR/nix-store" <<'EOF'
#!/usr/bin/env bash
printf 'nix-store' >>"$CALL_LOG"
printf ' <%s>' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
EOF

cat >"$BIN_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo' >>"$CALL_LOG"
printf ' <%s>' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
"$@"
EOF

cat >"$BIN_DIR/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh' >>"$CALL_LOG"
printf ' <%s>' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
cat >/dev/null
EOF

chmod +x "$BIN_DIR/nix-env" "$BIN_DIR/nix-store" "$BIN_DIR/ssh" "$BIN_DIR/sudo"

export CALL_LOG
NIX_GC_PROFILE_ROOT="$PROFILE_ROOT" \
  NIX_GC_SYSTEM_PROFILE="$SYSTEM_PROFILE" \
  NIX_ENV_BIN="$BIN_DIR/nix-env" \
  NIX_STORE_BIN="$BIN_DIR/nix-store" \
  SUDO_BIN="$BIN_DIR/sudo" \
  "$MAINTENANCE" >/dev/null

expected=$(
  cat <<EOF
nix-env <--profile> <$PROFILE_ROOT/home-manager> <--delete-generations> <+10>
nix-env <--profile> <$PROFILE_ROOT/profile> <--delete-generations> <+10>
sudo <$BIN_DIR/nix-env> <--profile> <$SYSTEM_PROFILE> <--delete-generations> <+10>
nix-env <--profile> <$SYSTEM_PROFILE> <--delete-generations> <+10>
sudo <$BIN_DIR/nix-store> <--gc> <--max-freed> <10737418240>
nix-store <--gc> <--max-freed> <10737418240>
EOF
)

actual=$(cat "$CALL_LOG")
if [[ "$actual" != "$expected" ]]; then
  printf 'unexpected command sequence\nexpected:\n%s\nactual:\n%s\n' \
    "$expected" "$actual" >&2
  exit 1
fi

: >"$CALL_LOG"
SSH_BIN="$BIN_DIR/ssh" "$MAINTENANCE" nux >/dev/null

expected="ssh <-tt> <nux> <bash> <-s>"
actual=$(cat "$CALL_LOG")
if [[ "$actual" != "$expected" ]]; then
  printf 'unexpected remote command\nexpected:\n%s\nactual:\n%s\n' \
    "$expected" "$actual" >&2
  exit 1
fi

printf 'nix GC maintenance contract: PASS\n'
