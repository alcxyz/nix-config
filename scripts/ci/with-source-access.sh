#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${CI_SOURCE_READ_TOKEN:-}" || -z "${CI_SOURCE_READ_USER:-}" ]]; then
  echo 'Configuration source access is not provisioned; validation cannot run.' >&2
  exit 1
fi
if (($# == 0)); then
  echo 'Usage: with-source-access.sh COMMAND [ARG ...]' >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=url.https://git.alc.xyz/.insteadOf
export GIT_CONFIG_VALUE_0=ssh://git@git-ssh.alc.xyz/
export GIT_CONFIG_KEY_1=credential.helper
export GIT_CONFIG_VALUE_1=
export GIT_CONFIG_KEY_2=credential.https://git.alc.xyz.helper
CI_CREDENTIAL_HELPER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/git-source-credentials.sh"
export CI_CREDENTIAL_HELPER
# Git must expand this variable when it invokes the helper, not during setup.
# shellcheck disable=SC2016
export GIT_CONFIG_VALUE_2='!bash "$CI_CREDENTIAL_HELPER"'

if "$@" >"$work/check.log" 2>&1; then
  echo 'Validation command passed.'
else
  status=$?
  echo 'Validation failed. Reproduce the candidate in the authorized development environment for diagnostics.' >&2
  exit "$status"
fi
