# flake.nix
{
  description = "NixOS and Nix-Darwin configurations for multiple hosts with \
                standalone Home Manager (all on nixos-unstable)";

  # ---- Inputs -----------------------------------------------------------
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nix-secrets = {
      #url = "path:/home/alc/nix-secrets";
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/nix-secrets.git";
      flake = false;
    };

    nix-packages = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/nix-packages.git";
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
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/paperflow.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    paperless-tools = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/paperless-tools.git?ref=dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    leantime-tidy = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/leantime-tidy.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    grove = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/grove.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    canopy = {
      url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/canopy.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dms-plugins.url = "git+ssh://git@git-ssh.alc.xyz/alcxyz/dms-plugins.git";
  };

  # ---- Outputs ----------------------------------------------------------
  outputs = {
    self,
    nixpkgs,
    nix-packages,
    nix-secrets,
    darwin,
    home-manager,
    nix-colors,
    sops-nix,
    ...
  } @ inputs: let
    # Basic identity values
    username = "alc";
    lib = nixpkgs.lib;

    # Systems we support in this flake (add more if needed)
    supportedSystems = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];

    # genAttrs helper to create per-system pkgs attrs
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

    pkgsFor = forAllSystems (
      system: let
        overlays = [
          (
            _final: _prev: let
              np = nix-packages.packages.${system};
              wanted = [
                "forge-mirror"
                "ndrop"
                "zfs-auto-unlock"
                "helium"
                "t3code"
                "claude-code"
                "devlog"
                "agent-sync-check"
                "omniwm"
                "zen-browser"
                "nix-deploy"
                "wcap"
              ];
              pt = inputs.paperless-tools.packages.${system} or {};
              lt = inputs.leantime-tidy.packages.${system} or {};
            in
              (nixpkgs.lib.filterAttrs (n: _: builtins.elem n wanted) np)
              // (nixpkgs.lib.filterAttrs (
                  n: _:
                    builtins.elem n [
                      "paperweight"
                      "paperless-filetype-index"
                    ]
                )
                pt)
              // (nixpkgs.lib.filterAttrs (
                  n: _:
                    builtins.elem n [
                      "leantime-tidy"
                    ]
                )
                lt)
              # SentinelOne kills freshly-built binaries during test phase on macOS.
              # Skip nushell tests to avoid build failure on managed Macs.
              // nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") {
                nushell = _prev.nushell.overrideAttrs {doCheck = false;};
              }
          )
        ];
      in
        import nixpkgs {
          inherit system overlays;
          config.allowUnfree = true;
          config.allowUnsupportedSystem = true;
        }
    );

    inventory = import ./inventory.nix;
    inventoryHosts = inventory.hosts;

    # ----- Host definitions ------------------------------------------------
    # Add / remove hosts in inventory.nix.
    nixosHosts = lib.filterAttrs (_: hostAttrs: hostAttrs.platform == "nixos") inventoryHosts;
    darwinHosts = lib.filterAttrs (_: hostAttrs: hostAttrs.platform == "darwin") inventoryHosts;

    # ---- Build NixOS systems ------------------------------------------------
    allNixosSystems =
      builtins.mapAttrs (
        hostName: hostAttrs:
          nixpkgs.lib.nixosSystem {
            # Provide host-specific specialArgs; pass pkgs for that system
            specialArgs = {
              inherit inputs inventory hostName username;
              configDir = self;
              hostInventory = hostAttrs;
              hostRole = inventory.roles.${hostAttrs.role};
              hostK8sRole =
                if hostAttrs.k8sRole == null
                then null
                else inventory.k8sRoles.${hostAttrs.k8sRole};
            };
            modules = [
              nixpkgs.nixosModules.readOnlyPkgs
              {nixpkgs.pkgs = pkgsFor.${hostAttrs.system};}
              hostAttrs.configuration
              sops-nix.nixosModules.sops
            ];
          }
      )
      nixosHosts;

    # ---- Build darwin systems ------------------------------------------------
    allDarwinSystems =
      builtins.mapAttrs (
        hostName: hostAttrs:
          darwin.lib.darwinSystem {
            specialArgs = {
              inherit inputs inventory hostName username;
              configDir = self;
              hostInventory = hostAttrs;
              hostRole = inventory.roles.${hostAttrs.role};
              hostK8sRole = null;
              pkgs = pkgsFor.${hostAttrs.system};
            };
            modules = [
              {nixpkgs.hostPlatform = hostAttrs.system;}
              hostAttrs.configuration
              sops-nix.darwinModules.sops
            ];
          }
      )
      darwinHosts;

    # ---- Home Manager configurations ---------------------------------------
    # Use the same unstable pkgs for Home Manager so user modules match packages.
    mkHomeConfiguration = hostName: hostAttrs: homeConfigPath:
      home-manager.lib.homeManagerConfiguration {
        # key: make Home Manager use the same pkgsFor (unstable pkgs)
        pkgs = pkgsFor.${hostAttrs.system};

        extraSpecialArgs = {
          # make inputs and some helper values available inside HM modules
          inherit
            inputs
            inventory
            username
            hostName
            ;
          configDir = self;
          system = hostAttrs.system;
          osIcon = hostAttrs.osIcon;
          hostInventory = hostAttrs;
          hostRole = inventory.roles.${hostAttrs.role};
          hostK8sRole =
            if hostAttrs.k8sRole == null
            then null
            else inventory.k8sRoles.${hostAttrs.k8sRole};
        };

        # Load the host-specific home config and some shared HM modules
        modules = [
          homeConfigPath
          inputs.nix-colors.homeManagerModules.default
          sops-nix.homeManagerModules.sops
        ];
      };

    homeConfigurations = let
      nixosHomeConfigs =
        lib.mapAttrs' (
          hostName: hostAttrs:
            lib.nameValuePair "${username}-${hostName}" (
              mkHomeConfiguration hostName hostAttrs ./users/${username}/linux/${hostName}.nix
            )
        )
        nixosHosts;

      darwinHomeConfigs =
        lib.mapAttrs' (
          hostName: hostAttrs:
            lib.nameValuePair "${username}-${hostName}" (
              mkHomeConfiguration hostName hostAttrs ./users/${username}/darwin/${hostName}.nix
            )
        )
        darwinHosts;
    in
      nixosHomeConfigs // darwinHomeConfigs;
  in {
    # ---- Exported configurations ------------------------------------------
    nixosConfigurations = allNixosSystems;
    darwinConfigurations = allDarwinSystems;

    # Home Manager configurations per-host (user)
    homeConfigurations = homeConfigurations;

    # Dev shells (per-system)
    devShells = forAllSystems (system: {
      default = pkgsFor.${system}.mkShell {
        nativeBuildInputs = with pkgsFor.${system}; [
          treefmt
          alejandra
          shfmt
        ];
      };
    });

    # Packages: add cross-build helpers for Rock Pi 4 (build on xyz).
    packages = forAllSystems (
      system: let
        pkgs = pkgsFor.${system};
      in
        if system == "x86_64-linux"
        then {
          # Cross-compiled U-Boot for Rock Pi 4 (RK3399).
          rpi0-uboot = pkgs.pkgsCross.aarch64-multiplatform.ubootRockPi4;

          # Convenience derivation that collects the two files you need to copy.
          rpi0-uboot-files = pkgs.runCommand "rpi0-uboot-files" {} ''
            set -e
            outdir="$out/share/rockpi4"
            mkdir -p "$outdir"
            cp ${pkgs.pkgsCross.aarch64-multiplatform.ubootRockPi4}/idbloader.img "$outdir/"
            cp ${pkgs.pkgsCross.aarch64-multiplatform.ubootRockPi4}/u-boot.itb "$outdir/"
            echo "Wrote Rock Pi 4 boot files to $outdir"
          '';
        }
        else {}
    );
  };
}
