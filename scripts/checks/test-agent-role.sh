#!/usr/bin/env bash
# Contract tests for the agent-role resolver (ADR-0079).
set -euo pipefail

script=modules/home-manager/programs/ai/agent-role.sh
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
cat >"$tmp/roles.json" <<'JSON'
{"build": {"description": "Bounded implementation.", "codex": {"model": "gpt-x", "effort": "medium"}, "claude": {"model": "opus", "effort": "medium"}},
 "deep": {"description": "Deep work.", "codex": {"model": "gpt-x", "effort": "high"}, "claude": {"model": "opus", "effort": "high"}}}
JSON
export AGENT_ROLES_FILE=$tmp/roles.json

test "$(bash "$script" build claude model)" = opus
test "$(bash "$script" deep codex effort)" = high
bash "$script" list | grep -qx $'deep\tDeep work.'
if bash "$script" nope claude model 2>"$tmp/err"; then exit 1; fi
grep -q "unknown role 'nope'; known roles: build, deep" "$tmp/err"
if bash "$script" build gemini model 2>/dev/null; then exit 1; fi
if bash "$script" build claude 2>/dev/null; then exit 1; fi
if AGENT_ROLES_FILE=$tmp/missing.json bash "$script" list 2>"$tmp/err"; then exit 1; fi
grep -q 'no role table' "$tmp/err"
echo "agent-role tests passed"
