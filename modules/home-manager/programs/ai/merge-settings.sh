#!/usr/bin/env bash
set -euo pipefail

settings_file=$1
managed_settings=$2
settings_tmp=""

cleanup() {
  if [ -n "$settings_tmp" ]; then
    rm -f -- "$settings_tmp"
  fi
}
trap cleanup EXIT

fail() {
  printf 'Cannot update Claude settings at %s: %s; existing settings were preserved.\n' "$settings_file" "$1" >&2
  exit 1
}

mkdir -p -- "$(dirname "$settings_file")" || fail 'cannot create settings directory'
settings_tmp=$(mktemp "$settings_file.tmp.XXXXXX") || fail 'cannot create temporary file'

if [ -e "$settings_file" ] || [ -L "$settings_file" ]; then
  jq -e -s '
    if length == 2 and all(.[]; type == "object") then
      .[0] * .[1]
    else
      error("expected one JSON object in each settings file")
    end
  ' "$settings_file" "$managed_settings" >"$settings_tmp" || fail 'JSON validation or merge failed'
else
  jq -e -s '
    if length == 1 and (.[0] | type == "object") then .[0]
    else error("expected one managed settings object") end
  ' "$managed_settings" >"$settings_tmp" || fail 'managed settings validation failed'
fi

chmod 600 "$settings_tmp" || fail 'cannot set temporary file permissions'
mv -f -- "$settings_tmp" "$settings_file" || fail 'cannot replace settings file'
