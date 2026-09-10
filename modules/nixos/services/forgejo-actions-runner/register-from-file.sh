#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 8 ]; then
  echo "usage: $0 RUNNER CONFIG RUNNER_FILE LABELS_FILE NAME_FILE INSTANCE NAME LABELS" >&2
  exit 2
fi

runner_command=$1
config_file=$2
runner_file=$3
labels_file=$4
name_file=$5
instance=$6
name=$7
labels=$8

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

labels_current="$(cat "$labels_file" 2>/dev/null || true)"
name_current="$(cat "$name_file" 2>/dev/null || true)"

if [ -f "$runner_file" ] && [ "$labels_current" = "$labels" ] && [ "$name_current" = "$name" ]; then
  exit 0
fi

rm -f "$runner_file"
{
  printf '%s\n' "$instance"
  tr -d '\n'
  printf '\n%s\n%s\n' "$name" "$labels"
} | "$runner_command" register --config "$config_file"

printf '%s\n' "$labels" > "$labels_file"
printf '%s\n' "$name" > "$name_file"
