#!/usr/bin/env bash
# Resolve an agent role (ADR-0079) for invocations that skip user configuration,
# such as Claude Code's --safe-mode or --restricted and Codex's
# --ignore-user-config, where role profiles and agent definitions are not loaded.
#
#   agent-role <role> <codex|claude> <model|effort>
#   agent-role list
set -euo pipefail

roles_file=${AGENT_ROLES_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-roles/roles.json}

usage() {
  echo 'Usage: agent-role <role> <codex|claude> <model|effort> | agent-role list' >&2
  exit 2
}

if [ ! -r "$roles_file" ]; then
  echo "agent-role: no role table at $roles_file; deploy the agent roles first." >&2
  exit 1
fi

if [ "$#" -eq 1 ] && [ "$1" = list ]; then
  jq -r 'to_entries[] | "\(.key)\t\(.value.description)"' "$roles_file"
  exit 0
fi
[ "$#" -eq 3 ] || usage
case $2 in codex | claude) ;; *) usage ;; esac
case $3 in model | effort) ;; *) usage ;; esac

if ! jq -e --arg role "$1" 'has($role)' "$roles_file" >/dev/null; then
  echo "agent-role: unknown role '$1'; known roles: $(jq -r 'keys | join(", ")' "$roles_file")." >&2
  exit 1
fi
jq -er --arg role "$1" --arg client "$2" --arg field "$3" '.[$role][$client][$field]' "$roles_file"
