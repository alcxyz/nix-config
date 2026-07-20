# flake.nix
{
  description = "NixOS and Nix-Darwin configurations for multiple hosts with \
                standalone Home Manager (all on nixos-unstable)";

  # ---- Inputs -----------------------------------------------------------
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-zfs-master.url = "github:NixOS/nixpkgs/master";

    flake-parts.url = "github:hercules-ci/flake-parts";

    nix-secrets = {
      #url = "path:/home/alc/nix-secrets";
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/nix-secrets.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-packages = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/nix-packages.git?ref=dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    paneru = {
      url = "github:alcxyz/paneru?ref=qa/alc-dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    bn-bootstrap = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/bn-bootstrap.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # color schemes, small extras
    nix-colors.url = "github:alcxyz/nix-colors";

    darwin = {
      url = "github:nix-darwin/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hyprland.url = "github:hyprwm/Hyprland";

    hyprland-plugins = {
      url = "github:hyprwm/hyprland-plugins";
      inputs.hyprland.follows = "hyprland";
    };

    quickshell = {
      url = "git+https://git.outfoxxed.me/outfoxxed/quickshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dsearch = {
      url = "github:AvengeMedia/danksearch";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dankMaterialShell = {
      url = "github:AvengeMedia/DankMaterialShell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hyprscratch = {
      url = "github:sashetophizika/hyprscratch";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    paperflow = {
      url = "github:alcxyz/paperflow";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    rustfs = {
      url = "github:rustfs/rustfs/1.0.0-beta.10";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    paperless-tools = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/paperless-tools.git?ref=dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    stashdb-pop = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/stashdb-pop.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    vidown = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/vidown.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    videdupe = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/videdupe.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    grove = {
      url = "github:alcxyz/grove/dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    canopy = {
      url = "github:alcxyz/canopy";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dms-plugins.url = "github:alcxyz/dms-plugins/main";
  };

  # ---- Outputs ----------------------------------------------------------
  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [
        ./flake/core.nix
        ./flake/hosts
        ./flake/per-system.nix
      ];
    };
}
