default:
    @just --list

[group("checks")]
check:
    nix flake check --keep-going

[group("checks")]
fmt-check:
    nix develop -c alejandra --check flake/per-system.nix flake/hosts/lib.nix hosts/madsil/configuration.nix hosts/madsil/hardware-configuration.nix hosts/mac/configuration.nix hosts/nex/configuration.nix hosts/nux/configuration.nix hosts/rpi0/configuration.nix hosts/xev/configuration.nix hosts/xps/configuration.nix hosts/xps/hardware-configuration.nix hosts/xyz/configuration.nix modules/home-manager/programs/ssh/default.nix modules/nixos/common/default.nix modules/nixos/common/distributed-build-client.nix modules/nixos/common/pkgsets.nix modules/nixos/common/server.nix modules/nixos/common/ssh-keys.nix modules/nixos/services/flatpak/default.nix modules/nixos/services/heroic-sideload/default.nix modules/nixos/services/k8s-api-vip/default.nix modules/nixos/virtualisation/k3s/default.nix modules/shared/host-metadata.nix modules/shared/pkgsets.nix packages/nix-deploy/default.nix users/alc/common.nix users/alc/linux/madsil.nix users/alc/linux/common.nix users/alc/linux/nex.nix users/alc/linux/nux.nix users/alc/linux/operator.nix users/alc/linux/rpi0.nix users/alc/linux/xev.nix users/alc/linux/xps.nix users/alc/linux/xyz.nix users/madsil/linux/madsil.nix
    nix develop -c shfmt -d -i 2 -ci scripts/checks/*.sh scripts/ops/*.sh packages/nix-deploy/deploy

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
    nix develop -c shfmt -w -i 2 -ci scripts/checks/*.sh scripts/ops/*.sh packages/nix-deploy/deploy

[group("ops")]
k8s-node-reboot HOST:
    kreboot {{HOST}}

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
