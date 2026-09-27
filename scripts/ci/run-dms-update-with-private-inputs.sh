#!/usr/bin/env bash
set -euo pipefail

: "${DMS_PRIVATE_INPUT_TOKEN:?missing DMS_PRIVATE_INPUT_TOKEN}"
auth_dir=$(mktemp -d)
chmod 700 "$auth_dir"
trap 'rm -rf "$auth_dir"' EXIT
umask 077
printf '%s' "$DMS_PRIVATE_INPUT_TOKEN" >"$auth_dir/token"
unset DMS_PRIVATE_INPUT_TOKEN

cat >"$auth_dir/credential-helper" <<'EOF'
#!/bin/sh
[ "$1" = get ] || exit 0
protocol=
host=
while IFS='=' read -r key value; do
  case "$key" in
    protocol) protocol=$value ;;
    host) host=$value ;;
  esac
done
[ "$protocol" = https ] && [ "$host" = git.alc.xyz ] || exit 0
printf 'username=token\npassword='
cat "$DMS_INPUT_TOKEN_FILE"
printf '\n'
EOF
chmod 700 "$auth_dir/credential-helper"
cat >"$auth_dir/gitconfig" <<EOF
[url "https://git.alc.xyz/"]
    insteadOf = ssh://git@git-ssh.alc.xyz/
[credential]
    helper =
[credential "https://git.alc.xyz"]
    helper = !$auth_dir/credential-helper
EOF
export DMS_INPUT_TOKEN_FILE="$auth_dir/token"
export GIT_CONFIG_GLOBAL="$auth_dir/gitconfig"
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false
export SSH_ASKPASS=/bin/false
scripts/update-inputs/update-dms-plugins.sh
