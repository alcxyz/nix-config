default:
    @just --list

[group("checks")]
check:
    nix flake check --keep-going

[group("checks")]
fmt-check:
    nix develop -c alejandra --check flake/per-system.nix modules/home-manager/host-metadata/default.nix modules/home-manager/programs/ssh/default.nix modules/nixos/common/default.nix modules/nixos/common/host-metadata.nix modules/nixos/common/ssh-keys.nix users/alc/common.nix
    nix develop -c shfmt -d -i 2 -ci scripts/checks/*.sh

[group("checks")]
hygiene:
    nix develop -c scripts/checks/forbid-submodules.sh
    nix develop -c scripts/checks/destroyed-symlinks.sh

[group("checks")]
pre-commit:
    nix develop -c pre-commit run

[group("format")]
fmt:
    nix develop -c alejandra .
    nix develop -c shfmt -w -i 2 -ci scripts/checks/*.sh

[group("building")]
rebuild HOST=`hostname`:
    sudo nixos-rebuild switch --flake .#{{HOST}}

[group("building")]
home HOST=`hostname`:
    home-manager switch --flake .#alc-{{HOST}}

[group("building")]
darwin HOST=`hostname`:
    sudo darwin-rebuild switch --flake .#{{HOST}}

[group("deploy")]
deploy HOST:
    deploy {{HOST}}

[group("deploy")]
deploy-nixos HOST:
    deploy --nixos {{HOST}}

[group("deploy")]
deploy-home HOST:
    deploy --hm {{HOST}}

[group("workspace")]
workspace-status:
    workspace-sync --status

[group("update")]
update *INPUTS:
    nix flake update {{INPUTS}}
