#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 7 ]; then
  echo "usage: $0 RUNNER CONFIG RUNNER_FILE NAME_FILE INSTANCE NAME LABELS" >&2
  exit 2
fi

runner_command=$1
config_file=$2
runner_file=$3
name_file=$4
instance=$5
name=$6
labels=$7

for value in "$instance" "$name" "$labels"; do
  if [ -z "$value" ]; then
    echo "runner registration settings must not be empty" >&2
    exit 2
  fi
  case "$value" in
    *$'\n'* | *$'\r'*)
      echo "runner registration settings must contain exactly one line" >&2
      exit 2
      ;;
  esac
done

name_current="$(cat "$name_file" 2>/dev/null || true)"

# The daemon declares configured labels on startup; changing them keeps identity.
if [ -f "$runner_file" ] && [ "$name_current" = "$name" ]; then
  exit 0
fi

rm -f "$runner_file"
{
  printf '%s\n' "$instance"
  tr -d '\n'
  printf '\n%s\n%s\n' "$name" "$labels"
} | "$runner_command" register --config "$config_file"

printf '%s\n' "$name" > "$name_file"
