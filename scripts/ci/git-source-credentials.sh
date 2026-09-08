#!/usr/bin/env bash
set -euo pipefail

# Git invokes this helper over stdin/stdout; never invoke it for diagnostics.
[[ "${1:-}" == get ]] || exit 0
protocol=
host=
while IFS='=' read -r key value; do
  case "$key" in
    protocol) protocol=$value ;;
    host) host=$value ;;
  esac
done
if [[ "$protocol" == https && "$host" == git.alc.xyz ]]; then
  : "${CI_SOURCE_READ_TOKEN:?Configuration source access is not provisioned}"
  : "${CI_SOURCE_READ_USER:?Configuration source identity is not provisioned}"
  printf 'username=%s\npassword=%s\n' "$CI_SOURCE_READ_USER" "$CI_SOURCE_READ_TOKEN"
fi
