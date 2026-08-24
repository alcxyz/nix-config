#!/usr/bin/env bash
set -euo pipefail

lock_file=${1:-flake.lock}

readarray -t lock_fields < <(
	python3 - "$lock_file" <<'PYEOF'
import json
import sys

node = json.load(open(sys.argv[1]))["nodes"]["nix-packages"]["locked"]
for key in ("url", "ref", "rev"):
    print(node[key])
PYEOF
)

locked_url=${lock_fields[0]}
locked_ref=${lock_fields[1]}
locked_rev=${lock_fields[2]}
flake_uri="git+${locked_url}?ref=${locked_ref}&rev=${locked_rev}"

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

t3_out=$(nix build "${flake_uri}#t3code" --no-link --print-out-paths)
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

for package in claude-code codex-cli codex-app-server t3code; do
	grep -Fq "$package" modules/shared/pkgsets.nix ||
		{
			echo "AI package set is missing ${package}" >&2
			exit 1
		}
	grep -Fq "\"$package\"" flake/pkgs.nix ||
		{
			echo "nix-packages overlay whitelist is missing ${package}" >&2
			exit 1
		}
done

printf 'Verified locked AI package stack at %s:\n' "$locked_rev"
printf '  T3 Code:         %s\n' "$t3_version"
printf '  Claude Code:     %s\n' "$claude_version"
printf '  Codex CLI:       %s (embedded app-server)\n' "$codex_version"
printf '  Codex app server:%s (standalone)\n' "$app_server_version"
