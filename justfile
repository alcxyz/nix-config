default:
    @just --list

[group("checks")]
check:
    nix flake check --keep-going

[group("checks")]
fmt-check:
    nix develop -c treefmt --ci

[group("checks")]
hygiene:
    nix develop -c scripts/checks/forbid-submodules.sh
    nix develop -c scripts/checks/destroyed-symlinks.sh

[group("checks")]
input:
    nix develop -c bash scripts/checks/test-wolf-browser-input-contract.sh

[group("checks")]
pre-commit:
    nix develop -c pre-commit run

[group("format")]
fmt:
    nix develop -c treefmt

[group("ops")]
k8s-node-reboot HOST:
    kreboot {{HOST}}

[group("ops")]
gc HOST="":
    if [ -n "{{HOST}}" ]; then scripts/ops/nix-gc-maintenance.sh "{{HOST}}"; else scripts/ops/nix-gc-maintenance.sh; fi

[group("ops")]
k8s-node-preflight HOST:
    kreboot --check-only {{HOST}}

[group("ops")]
k8s-node-maintenance-check HOST:
    koff --resume-maintenance --check-only {{HOST}}

[group("ops")]
k8s-node-poweroff HOST:
    koff {{HOST}}

[group("ops")]
k8s-node-poweroff-again HOST:
    koff --resume-maintenance {{HOST}}

[group("ops")]
k8s-node-poweron HOST:
    kon {{HOST}}

[group("ops")]
stats HOST:
    ssh root@{{HOST}} "journalctl -t moonlight-direct-drm --since '2 minutes ago' -o cat --no-pager | grep -E 'Rolling video stats|Video stream:|frame rate|Frames dropped|Average |queue overflow|IDR frame request'"

[group("ops")]
ssd-health DEVICE:
    sudo scripts/ops/ssd-health-check.sh {{DEVICE}}

[group("ops")]
ssd-health-thorough DEVICE:
    sudo scripts/ops/ssd-health-check.sh --start-long --wait-long --read-scan {{DEVICE}}

[group("building")]
rebuild HOST=`hostname`:
    sudo nixos-rebuild switch --flake .#{{HOST}}

[group("building")]
home HOST=`hostname`:
    home-manager switch --flake .#alc-{{HOST}}

[group("building")]
home-dry-run HOST=`hostname`:
    # Evaluate the target host's Home Manager closure without realizing it locally.
    system="$(nix eval --impure --raw --expr '(import ./inventory.nix).hosts."{{HOST}}".system')" && nix build --system "$system" --dry-run --no-link .#homeConfigurations.alc-{{HOST}}.activationPackage

[group("building")]
darwin HOST=`hostname`:
    sudo darwin-rebuild switch --flake .#{{HOST}}

[group("building")]
darwin-dry-run HOST='mac':
    # Evaluate the nix-darwin system closure without requiring a local Darwin builder.
    system="$(nix eval --impure --raw --expr '(import ./inventory.nix).hosts."{{HOST}}".system')" && nix build --system "$system" --dry-run --no-link .#darwinConfigurations.{{HOST}}.system

[group("deploy")]
deploy HOST:
    nix run .#nix-deploy -- {{HOST}}

[group("deploy")]
deploy-nixos HOST:
    nix run .#nix-deploy -- --nixos {{HOST}}

[group("deploy")]
deploy-home HOST:
    nix run .#nix-deploy -- --hm {{HOST}}

[group("workspace")]
workspace-status:
    workspace-sync --status

[group("update")]
update *INPUTS:
    nix flake update {{INPUTS}}

# Refresh maintained dev projects only; inspect the lock diff before switching.
[group("update")]
qa-update:
    bash scripts/update-inputs/update-maintained.sh
