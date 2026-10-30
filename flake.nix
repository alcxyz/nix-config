# flake.nix
{
  description = "NixOS and Nix-Darwin configurations for multiple hosts with \
                standalone Home Manager (all on nixos-unstable)";

  # ---- Inputs -----------------------------------------------------------
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Hold host OpenBao at the reviewed 2.6.2 until adoption finishes and the
    # next release is reviewed; remove once nixpkgs' version is accepted.
    nixpkgs-openbao.url = "github:NixOS/nixpkgs/6774f7bc253789b113a4f39285dc0fa100abeacc";
    # Previous working package set for Azure CLI, Khal and Calibre. Azure CLI
    # remains here until fabric supports invoke 3:
    # https://github.com/fabric/fabric/issues/2376
    nixpkgs-azure-cli.url = "github:NixOS/nixpkgs/55bfb4d7437bd4e09ab7cba58a43bd68eb310044";

    nixos-hardware = {
      url = "github:NixOS/nixos-hardware/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-parts.url = "github:hercules-ci/flake-parts";

    nix-secrets = {
      #url = "path:/home/alc/nix-secrets";
      url = "git+https://git.alc.xyz/alcxyz/nix-secrets.git?ref=dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The private agent stack: rules, skills, programs.ai and the agent
    # modules, fetched like nix-secrets.
    pandora = {
      url = "git+https://git.alc.xyz/alcxyz/pandora.git?ref=dev";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    nix-packages = {
      # Public HTTPS keeps the lock refresh usable by unattended CI without
      # distributing an SSH identity merely to read public package sources.
      url = "git+https://git.alc.xyz/alcxyz/nix-packages.git?ref=dev";
      # Both nixpkgs inputs, so its packages run on the hosts' own nixpkgs
      # (ADR-0104).
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixpkgs-unstable.follows = "nixpkgs";
    };

    reportcraft = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/reportcraft.git?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Nightly development statistics collector: package and Home Manager
    # module; nix-secrets supplies its private settings. Released tool,
    # refreshed by tools-update (ADR-0086).
    devstats = {
      url = "git+https://git.alc.xyz/alcxyz/devstats.git?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Installed from its own flake; the private work flake supplies only its
    # work configuration (ADR-0090). Released app, refreshed by apps-update; its dev
    # build is refreshed by dev-apps-update (ADR-0089).
    bivrost = {
      url = "github:alcxyz/bivrost/main";
      inputs.nixpkgs.follows = "nixpkgs-azure-cli";
    };

    bivrost-dev = {
      url = "github:alcxyz/bivrost/dev";
      inputs.nixpkgs.follows = "nixpkgs-azure-cli";
    };

    # The private work flake: Bivrost catalogue, Boards and backlog groups.
    work = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/bn-bootstrap.git?ref=dev";
      inputs.nixpkgs.follows = "nixpkgs-azure-cli";
    };

    # color schemes, small extras
    nix-colors.url = "github:Misterio77/nix-colors";

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

    quickshell = {
      url = "git+https://git.outfoxxed.me/outfoxxed/quickshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dsearch = {
      url = "github:AvengeMedia/danksearch";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dankMaterialShell = {
      # Track stable releases explicitly: DMS is part of the interactive
      # desktop, so development-branch churn is a poor fit here.
      url = "github:AvengeMedia/DankMaterialShell/v1.5.3";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hyprscratch = {
      url = "github:sashetophizika/hyprscratch";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    paperflow = {
      url = "github:alcxyz/paperflow/dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Application storage is qualified independently of the backup service.
    rustfs-app = {
      url = "github:rustfs/rustfs/1.0.0-rc.6";
      inputs.nixpkgs.follows = "rustfs-nixpkgs";
    };

    rustfs = {
      url = "github:rustfs/rustfs/1.0.0-beta.10";
      inputs.nixpkgs.follows = "rustfs-nixpkgs";
      inputs.rust-overlay.follows = "rustfs-rust-overlay";
    };

    # No binary cache serves the RustFS pins, so following the root nixpkgs
    # rebuilt both Rust workspaces on every update. They build from these
    # revision pins instead, which move only on purpose. The backup
    # service's rust-overlay is past the deprecated stdenv.isLinux and
    # stdenv.isDarwin, and the beta builds with its latest stable Rust.
    rustfs-nixpkgs.url = "github:NixOS/nixpkgs/3ec636362e1816bc2f0888fa0fa2c69f1bc9e504";

    rustfs-rust-overlay = {
      url = "github:oxalica/rust-overlay/c7e9d512653a35ef4d5879c3df4d44d7b78d0e6d";
      inputs.nixpkgs.follows = "rustfs-nixpkgs";
    };

    paperless-tools = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/paperless-tools.git?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    regnskap = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/regnskap.git?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Dev builds next to the released tools (ADR-0087); refreshed by dev-tools-update.
    paperless-tools-dev = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/paperless-tools.git?ref=dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    regnskap-dev = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/regnskap.git?ref=dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    t3rry = {
      url = "github:alcxyz/t3rry/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    t3rry-dev = {
      url = "github:alcxyz/t3rry/dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    stashdb-pop = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/stashdb-pop.git?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hedgedoc = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/hedgedoc.git?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # No releases yet, so it follows dev under its own name (ADR-0089).
    vidown = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/vidown.git?ref=dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Released apps follow main and are refreshed by apps-update; their dev
    # builds sit next to them and are refreshed by dev-apps-update (ADR-0089).
    grove = {
      url = "github:alcxyz/grove/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    grove-dev = {
      url = "github:alcxyz/grove/dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    canopy = {
      url = "github:alcxyz/canopy/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    canopy-dev = {
      url = "github:alcxyz/canopy/dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # No releases yet, so it follows dev under its own name (ADR-0089).
    paw = {
      url = "github:alcxyz/paw/dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Maintainer QA consumes integrated dev commits, still pinned by flake.lock.
    # Override sources here so the public bundle can retain release defaults.
    dms-plugins = {
      url = "github:alcxyz/dms-plugins/dev";
      inputs = {
        quicksearch.url = "github:alcxyz/DankQuickSearch/dev";
        vault.url = "github:alcxyz/DankVault/dev";
        translate.url = "github:alcxyz/DankTranslate/dev";
        spotify.url = "github:alcxyz/DankSpotify/dev";
        dankcalendar.url = "github:alcxyz/DankCalendar/dev";
        danksession.follows = "danksession";
        diskusage.url = "github:alcxyz/DankDiskUsage/dev";
        aiusage.url = "github:alcxyz/DankAIUsage/dev";
        displaycontrol.url = "github:alcxyz/DankDisplayControl/dev";
      };
    };

    danksession = {
      url = "github:alcxyz/DankSession/dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # ---- Outputs ----------------------------------------------------------
  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [
        ./flake/core.nix
        ./flake/hosts
        ./flake/modules.nix
        ./flake/per-system.nix
      ];
    };
}
