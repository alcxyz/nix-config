#!/usr/bin/env bash
set -euo pipefail

lock_argument=${1:-flake.lock}
homeless_shelter=/homeless-shelter

if (($# > 1)); then
  echo "Usage: $0 [path/to/flake.lock]" >&2
  exit 2
fi

if ! lock_file=$(realpath --canonicalize-existing -- "$lock_argument"); then
  echo "Unable to resolve consumer lock: ${lock_argument}" >&2
  exit 1
fi

consumer_flake_dir=$(dirname "$lock_file")
if [[ "$(basename "$lock_file")" != "flake.lock" || ! -f "${consumer_flake_dir}/flake.nix" ]]; then
  echo "Consumer lock must be the flake.lock beside the flake.nix being evaluated: ${lock_argument}" >&2
  exit 1
fi
consumer_flake_uri="path:${consumer_flake_dir}"

clean_homeless_shelter() {
  local attempt

  if [[ ! -e "$homeless_shelter" ]]; then
    return 0
  fi

  if [[ "${NIX_CI_EPHEMERAL_CONTAINER:-0}" != "1" || ! -e /.dockerenv ]]; then
    echo "Refusing to remove ${homeless_shelter} outside the declared ephemeral CI container." >&2
    return 1
  fi

  for attempt in {1..10}; do
    rm --recursive --force --one-file-system -- "$homeless_shelter"
    sleep 1
    if [[ ! -e "$homeless_shelter" ]]; then
      sleep 1
      [[ ! -e "$homeless_shelter" ]] && return 0
    fi
  done

  echo "Unable to keep ${homeless_shelter} absent before a non-sandboxed Nix build." >&2
  return 1
}

nix_build() {
  local attempt
  local output
  local status

  for attempt in 1 2 3; do
    clean_homeless_shelter
    if output=$(nix build "$@"); then
      [[ -z "$output" ]] || printf '%s\n' "$output"
      return 0
    else
      status=$?
    fi

    if [[ ! -e "$homeless_shelter" || "$attempt" -eq 3 ]]; then
      return "$status"
    fi

    echo "Retrying Nix build after ${homeless_shelter} was recreated (attempt $((attempt + 1))/3)." >&2
  done
}

if ! lock_data=$(
  python3 - "$lock_file" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as lock:
    node = json.load(lock)["nodes"]["nix-packages"]["locked"]
for key in ("url", "ref", "rev"):
    print(node[key])
PYEOF
); then
  echo "Unable to read nix-packages from ${lock_file}" >&2
  exit 1
fi
readarray -t lock_fields <<<"$lock_data"

locked_url=${lock_fields[0]}
locked_ref=${lock_fields[1]}
locked_rev=${lock_fields[2]}
flake_uri="git+${locked_url}?ref=${locked_ref}&rev=${locked_rev}"

if ! consumer_metadata=$(nix flake metadata --json --no-update-lock-file "$consumer_flake_uri"); then
  echo "Unable to resolve the consumer flake beside ${lock_file}" >&2
  exit 1
fi

if ! consumer_identity=$(
  python3 -c '
import hashlib
import json
import sys

lock_path = sys.argv[1]
metadata = json.load(sys.stdin)
with open(lock_path, "rb") as lock_file:
    lock_bytes = lock_file.read()
expected = json.loads(lock_bytes)

if metadata["locks"] != expected:
    print("Consumer flake metadata does not match the supplied lock graph", file=sys.stderr)
    sys.exit(1)
print(metadata["path"])
print(hashlib.sha256(lock_bytes).hexdigest())
' "$lock_file" <<<"$consumer_metadata"
); then
  exit 1
fi
readarray -t consumer_identity_fields <<<"$consumer_identity"
consumer_source=${consumer_identity_fields[0]}
consumer_lock_sha256=${consumer_identity_fields[1]}
consumer_snapshot_uri="path:${consumer_source}"

if ! consumer_revision=$(git -C "$consumer_flake_dir" rev-parse HEAD); then
  echo "Unable to identify the consumer configuration revision" >&2
  exit 1
fi

remote_url=${NIX_PACKAGES_REMOTE_URL:-https://git.alc.xyz/alcxyz/nix-packages.git}
remote_rev=$(git ls-remote "$remote_url" "refs/heads/${locked_ref}" | awk '{print $1}')
if [[ -z "$remote_rev" ]]; then
  echo "Unable to resolve nix-packages ${locked_ref}" >&2
  exit 1
fi

if [[ "$locked_rev" != "$remote_rev" ]]; then
  echo "nix-packages lock is stale: locked ${locked_rev}, upstream ${remote_rev}" >&2
  exit 1
fi

claude_version=$(nix eval --raw "${flake_uri}#claude-code.version")
codex_version=$(nix eval --raw "${flake_uri}#codex-cli.version")
app_server_version=$(nix eval --raw "${flake_uri}#codex-app-server.version")
t3_version=$(nix eval --raw "${flake_uri}#t3code.version")

# Forgejo executes this workflow in an unprivileged Docker container, where
# Nix cannot provide its normal inner build sandbox. Build the closure in
# stages so a dependency that writes to Nix's fake HOME cannot contaminate a
# concurrently starting derivation. The final assembly then uses cached inputs.
nix_build "${flake_uri}#claude-code" --no-link
nix_build "${flake_uri}#codex-cli" --no-link
nix_build "${flake_uri}#codex-app-server" --no-link
nix_build "${flake_uri}#t3code.pnpmDeps" --no-link
nix_build "${flake_uri}#t3code.resourceMonitor" --no-link
t3_out=$(nix_build "${flake_uri}#t3code" --no-link --print-out-paths)
references=$(nix-store -q --references "$t3_out")

grep -Eq -- "-claude-code-${claude_version}$" <<<"$references" ||
  {
    echo "T3 Code does not reference claude-code-${claude_version}" >&2
    exit 1
  }
grep -Eq -- "-codex-cli-${codex_version}$" <<<"$references" ||
  {
    echo "T3 Code does not reference codex-cli-${codex_version}" >&2
    exit 1
  }

consumer_system=${NIX_CONSUMER_SYSTEM:-$(nix eval --impure --raw --expr builtins.currentSystem)}
if [[ ! "$consumer_system" =~ ^[a-zA-Z0-9_+-]+$ ]]; then
  echo "Invalid consumer system selector: ${consumer_system}" >&2
  exit 1
fi

# This check deep-forces every exported NixOS, Home Manager, and Darwin
# deployment derivation without building their full closures.
nix_build --no-update-lock-file "${consumer_snapshot_uri}#checks.${consumer_system}.configuration-evaluation" --no-link

# The single-quoted expression contains Nix interpolation, not shell expansion.
# shellcheck disable=SC2016
if ! consumer_packages_json=$(
  NIX_CONSUMER_SYSTEM="$consumer_system" nix eval --no-update-lock-file --impure --json "${consumer_snapshot_uri}#homeConfigurations" --apply '
    homes: let
      system = builtins.getEnv "NIX_CONSUMER_SYSTEM";
      packageNames = [ "claude-code" "codex-cli" "codex-app-server" "t3code" ];
      nativeHomeNames = builtins.filter (
        name: homes.${name}.pkgs.stdenv.hostPlatform.system == system
      ) (builtins.attrNames homes);
      matchesFor = packageName:
        builtins.concatMap (
          homeName: let
            home = homes.${homeName};
            expectedDrv = home.pkgs.${packageName}.drvPath;
          in
            builtins.map
            (selected: {
              inherit homeName;
              drvPath = selected.drvPath;
              stagedDrvPaths =
                if packageName == "t3code"
                then [ selected.pnpmDeps.drvPath selected.resourceMonitor.drvPath ]
                else [];
            })
            (builtins.filter (
                selected: selected.drvPath == expectedDrv
              )
              home.config.home.packages)
        )
        nativeHomeNames;
    in
      builtins.listToAttrs (builtins.map (packageName: {
          name = packageName;
          value = matchesFor packageName;
        })
        packageNames)
  '
); then
  echo "Unable to evaluate AI packages selected by native consumer configurations" >&2
  exit 1
fi

if ! consumer_selections=$(
  python3 -c '
import json
import sys

package_names = ("claude-code", "codex-cli", "codex-app-server", "t3code")
selections = json.load(sys.stdin)
for package_name in package_names:
    matches = selections.get(package_name, [])
    if not matches:
        print(
            f"No native Home Manager configuration selects {package_name}",
            file=sys.stderr,
        )
        sys.exit(1)
    for match in matches:
        for drv_path in match["stagedDrvPaths"]:
            print("{}\t{}\tdependency\t{}".format(package_name, match["homeName"], drv_path))
        print("{}\t{}\tpackage\t{}".format(package_name, match["homeName"], match["drvPath"]))
' <<<"$consumer_packages_json"
); then
  exit 1
fi

declare -A built_consumer_drvs=()
while IFS=$'\t' read -r package home_name build_phase drv_path; do
  if [[ "$drv_path" != /nix/store/*.drv ]]; then
    echo "Consumer selected an invalid derivation path for ${package}: ${drv_path}" >&2
    exit 1
  fi
  printf '  Consumer %-17s %s (%s, %s)\n' "${package}:" "$drv_path" "$home_name" "$build_phase"
  if [[ ! -v "built_consumer_drvs[$drv_path]" ]]; then
    nix_build --no-update-lock-file "${drv_path}^*" --no-link
    built_consumer_drvs[$drv_path]=1
  fi
done <<<"$consumer_selections"

printf 'Verified producer/consumer revisions:\n'
printf '  nix-config:       %s (%s)\n' "$consumer_revision" "$consumer_source"
printf '  consumer lock:    sha256:%s\n' "$consumer_lock_sha256"
printf '  nix-packages:     %s\n' "$locked_rev"
printf '  T3 Code:         %s\n' "$t3_version"
printf '  Claude Code:     %s\n' "$claude_version"
printf '  Codex CLI:       %s (embedded app-server)\n' "$codex_version"
printf '  Codex app server:%s (standalone)\n' "$app_server_version"
