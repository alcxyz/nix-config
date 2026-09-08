#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
verifier=${repo_root}/scripts/ci/verify-ai-package-stack.sh
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

candidate_dir=${test_root}/candidate
other_dir=${test_root}/other
mock_bin=${test_root}/bin
mock_log=${test_root}/mock.log
locked_rev=1111111111111111111111111111111111111111
consumer_rev=2222222222222222222222222222222222222222
mkdir -p "$candidate_dir" "$other_dir" "$mock_bin"

printf '%s\n' '{ outputs = _: {}; }' >"${candidate_dir}/flake.nix"
printf '%s\n' "{
  \"nodes\": {
    \"nix-packages\": {
      \"locked\": {
        \"url\": \"https://example.invalid/nix-packages.git\",
        \"ref\": \"dev\",
        \"rev\": \"${locked_rev}\"
      }
    },
    \"other\": {
      \"locked\": {\"type\": \"path\", \"path\": \"./dependency\"},
      \"original\": {\"type\": \"path\", \"path\": \"./dependency\"}
    },
    \"root\": {
      \"inputs\": {\"nix-packages\": \"nix-packages\", \"other\": \"other\"}
    }
  },
  \"root\": \"root\",
  \"version\": 7
}" >"${candidate_dir}/flake.lock"

cat >"${mock_bin}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"$MOCK_LOG"
if [[ "$1" == "ls-remote" ]]; then
  printf '%s\trefs/heads/dev\n' "$MOCK_LOCKED_REV"
elif [[ "$1" == "-C" && "$3" == "rev-parse" && "$4" == "HEAD" ]]; then
  printf '%s\n' "$MOCK_CONSUMER_REV"
else
  echo "Unexpected git invocation: $*" >&2
  exit 97
fi
EOF

cat >"${mock_bin}/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'nix %s\n' "$*" >>"$MOCK_LOG"

if [[ "$1 $2" == "flake metadata" ]]; then
  other_path=${MOCK_OTHER_PATH:-./dependency}
  printf '{"path":"/nix/store/consumer-source","locks":{"nodes":{"nix-packages":{"locked":{"url":"https://example.invalid/nix-packages.git","ref":"dev","rev":"%s"}},"other":{"locked":{"type":"path","path":"%s"},"original":{"type":"path","path":"./dependency"}},"root":{"inputs":{"nix-packages":"nix-packages","other":"other"}}},"root":"root","version":7}}\n' "$MOCK_LOCKED_REV" "$other_path"
  exit 0
fi

if [[ "$1" == "eval" ]]; then
  case "$*" in
    *"#claude-code.version"*) printf '2.1.263' ;;
    *"#codex-cli.version"*) printf '0.153.4' ;;
    *"#codex-app-server.version"*) printf '0.153.4' ;;
    *"#t3code.version"*) printf '0.0.38' ;;
    *"#homeConfigurations"*)
      codex_cli='[{"homeName":"alc-first","drvPath":"/nix/store/consumer-codex-cli.drv","stagedDrvPaths":[]}]'
      if [[ "${MOCK_MISSING_PACKAGE:-}" == "codex-cli" ]]; then
        codex_cli='[]'
      fi
      printf '%s\n' "{
        \"claude-code\": [
          {\"homeName\":\"alc-first\",\"drvPath\":\"/nix/store/consumer-claude-code.drv\",\"stagedDrvPaths\":[]},
          {\"homeName\":\"alc-second\",\"drvPath\":\"/nix/store/consumer-claude-code.drv\",\"stagedDrvPaths\":[]}
        ],
        \"codex-cli\": ${codex_cli},
        \"codex-app-server\": [{\"homeName\":\"alc-first\",\"drvPath\":\"/nix/store/consumer-codex-app-server.drv\",\"stagedDrvPaths\":[]}],
        \"t3code\": [{\"homeName\":\"alc-first\",\"drvPath\":\"/nix/store/consumer-t3code.drv\",\"stagedDrvPaths\":[\"/nix/store/consumer-t3code-pnpm-deps.drv\",\"/nix/store/consumer-t3code-resource-monitor.drv\"]}]
      }"
      ;;
    *)
      echo "Unexpected nix eval invocation: $*" >&2
      exit 96
      ;;
  esac
  exit 0
fi

if [[ "$1" == "build" ]]; then
  if [[ "$*" == *"#checks.x86_64-linux.configuration-evaluation"* && "${MOCK_CONSUMER_EVAL_FAIL:-0}" == "1" ]]; then
    echo "synthetic consumer-only evaluation failure" >&2
    exit 42
  fi
  if [[ "$*" == *"#t3code --no-link --print-out-paths"* ]]; then
    printf '%s\n' /nix/store/producer-t3code
  fi
  exit 0
fi

echo "Unexpected nix invocation: $*" >&2
exit 95
EOF

cat >"${mock_bin}/nix-store" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'nix-store %s\n' "$*" >>"$MOCK_LOG"
printf '%s\n' \
  /nix/store/source-claude-code-2.1.263 \
  /nix/store/source-codex-cli-0.153.4
EOF

chmod +x "${mock_bin}/git" "${mock_bin}/nix" "${mock_bin}/nix-store"

assert_log_contains() {
  local expected=$1
  rg --fixed-strings --quiet -- "$expected" "$mock_log" || {
    echo "Missing mock invocation: ${expected}" >&2
    return 1
  }
}

assert_log_excludes() {
  local unexpected=$1
  if rg --fixed-strings --quiet -- "$unexpected" "$mock_log"; then
    echo "Unexpected mock invocation: ${unexpected}" >&2
    return 1
  fi
}

run_verifier() {
  local candidate_lock=$1
  shift
  (
    cd "$other_dir"
    env \
      PATH="${mock_bin}:$PATH" \
      MOCK_CONSUMER_REV="$consumer_rev" \
      MOCK_LOCKED_REV="$locked_rev" \
      MOCK_LOG="$mock_log" \
      NIX_CONSUMER_SYSTEM=x86_64-linux \
      "$@" \
      bash "$verifier" "$candidate_lock"
  )
}

cp "${candidate_dir}/flake.lock" "${candidate_dir}/candidate.lock"
: >"$mock_log"
if run_verifier "${candidate_dir}/candidate.lock" >"${test_root}/mismatch.out" 2>&1; then
  echo "Verifier accepted a lock that was not the evaluated flake's flake.lock" >&2
  exit 1
fi
rg --fixed-strings --quiet 'Consumer lock must be the flake.lock beside the flake.nix being evaluated' "${test_root}/mismatch.out"
[[ ! -s "$mock_log" ]] || {
  echo "Verifier invoked external tools before rejecting a mismatched lock" >&2
  exit 1
}

: >"$mock_log"
if run_verifier "${candidate_dir}/flake.lock" MOCK_OTHER_PATH=./different-dependency >"${test_root}/metadata-mismatch.out" 2>&1; then
  echo "Verifier accepted consumer metadata with a different non-package lock node" >&2
  exit 1
fi
rg --fixed-strings --quiet 'Consumer flake metadata does not match the supplied lock graph' "${test_root}/metadata-mismatch.out"
assert_log_excludes 'nix build'

: >"$mock_log"
if run_verifier "${candidate_dir}/flake.lock" MOCK_CONSUMER_EVAL_FAIL=1 >"${test_root}/consumer-failure.out" 2>&1; then
  echo "Verifier accepted a consumer-only evaluation failure" >&2
  exit 1
fi
assert_log_contains 'nix build git+https://example.invalid/nix-packages.git?ref=dev&rev=1111111111111111111111111111111111111111#claude-code --no-link'
assert_log_contains 'nix build --no-update-lock-file path:/nix/store/consumer-source#checks.x86_64-linux.configuration-evaluation --no-link'
assert_log_excludes 'nix build --no-update-lock-file /nix/store/consumer-claude-code.drv^* --no-link'
if rg --fixed-strings --quiet 'Verified producer/consumer revisions' "${test_root}/consumer-failure.out"; then
  echo "Verifier reported success after a consumer-only failure" >&2
  exit 1
fi

: >"$mock_log"
if run_verifier "${candidate_dir}/flake.lock" MOCK_MISSING_PACKAGE=codex-cli >"${test_root}/missing-package.out" 2>&1; then
  echo "Verifier accepted a consumer with a missing selected package" >&2
  exit 1
fi
rg --fixed-strings --quiet 'No native Home Manager configuration selects codex-cli' "${test_root}/missing-package.out"
assert_log_excludes 'nix build --no-update-lock-file /nix/store/consumer-claude-code.drv^* --no-link'

: >"$mock_log"
if ! run_verifier "${candidate_dir}/flake.lock" >"${test_root}/success.out" 2>&1; then
  cat "${test_root}/success.out" >&2
  echo "Verifier rejected the complete producer/consumer fixture" >&2
  exit 1
fi
assert_log_contains "nix flake metadata --json --no-update-lock-file path:${candidate_dir}"
assert_log_contains 'nix eval --no-update-lock-file --impure --json path:/nix/store/consumer-source#homeConfigurations'
for package in claude-code codex-cli codex-app-server t3code; do
  assert_log_contains "nix build --no-update-lock-file /nix/store/consumer-${package}.drv^* --no-link"
done
assert_log_contains 'nix build --no-update-lock-file /nix/store/consumer-t3code-pnpm-deps.drv^* --no-link'
assert_log_contains 'nix build --no-update-lock-file /nix/store/consumer-t3code-resource-monitor.drv^* --no-link'
pnpm_line=$(rg --line-number --fixed-strings 'nix build --no-update-lock-file /nix/store/consumer-t3code-pnpm-deps.drv^* --no-link' "$mock_log" | awk -F: 'NR == 1 { print $1 }')
monitor_line=$(rg --line-number --fixed-strings 'nix build --no-update-lock-file /nix/store/consumer-t3code-resource-monitor.drv^* --no-link' "$mock_log" | awk -F: 'NR == 1 { print $1 }')
t3code_line=$(rg --line-number --fixed-strings 'nix build --no-update-lock-file /nix/store/consumer-t3code.drv^* --no-link' "$mock_log" | awk -F: 'NR == 1 { print $1 }')
if ((pnpm_line >= t3code_line || monitor_line >= t3code_line)); then
  echo "Verifier did not stage consumer T3 Code dependencies before the final package" >&2
  exit 1
fi
if [[ $(rg --fixed-strings --count 'nix build --no-update-lock-file /nix/store/consumer-claude-code.drv^* --no-link' "$mock_log") -ne 1 ]]; then
  echo "Verifier rebuilt a consumer derivation selected by multiple homes" >&2
  exit 1
fi
rg --fixed-strings --quiet "nix-config:       ${consumer_rev} (/nix/store/consumer-source)" "${test_root}/success.out"
lock_sha256=$(sha256sum "${candidate_dir}/flake.lock" | awk '{print $1}')
rg --fixed-strings --quiet "consumer lock:    sha256:${lock_sha256}" "${test_root}/success.out"
rg --fixed-strings --quiet "nix-packages:     ${locked_rev}" "${test_root}/success.out"

echo "AI package stack verifier contract tests passed"
