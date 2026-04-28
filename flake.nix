# flake.nix
{
  description = "NixOS and Nix-Darwin configurations for multiple hosts with \
                standalone Home Manager (all on nixos-unstable)";

  # ---- Inputs -----------------------------------------------------------
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nix-secrets = {
      #url = "path:/home/alc/nix-secrets";
      url = "git+ssh://git@github.com/alcxyz/nix-secrets.git";
      flake = false;
    };

    nix-packages = {
      url = "github:alcxyz/nix-packages";
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

    paperless-tools = {
      url = "git+ssh://git@github.com/alcxyz/paperless-tools.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    leantime-tidy = {
      url = "git+ssh://git@github.com/alcxyz/gitops.git?dir=tools/leantime-tidy";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    grove = {
      url = "github:alcxyz/grove";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dms-plugins.url = "github:alcxyz/dms-plugins";

  };

  # ---- Outputs ----------------------------------------------------------
  outputs =
    {
      self,
      nixpkgs,
      nix-packages,
      nix-secrets,
      darwin,
      home-manager,
      nix-colors,
      sops-nix,
      ...
    }@inputs:
    let
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
        system:
        let
          overlays = [
            (
              _final: _prev:
              let
                np = nix-packages.packages.${system};
                wanted = [
                  "forge-mirror"
                  "ndrop"
                  "zfs-auto-unlock"
                  "pihole-sync"
                  "helium"
                  "t3code"
                  "claude-code"
                  "devlog"
                  "omniwm"
                  "zen-browser"
                  "nix-deploy"
                ];
                pt = inputs.paperless-tools.packages.${system} or { };
                lt = inputs.leantime-tidy.packages.${system} or { };
              in
              (nixpkgs.lib.filterAttrs (n: _: builtins.elem n wanted) np)
              // (nixpkgs.lib.filterAttrs (
                n: _:
                builtins.elem n [
                  "paperless-review"
                  "paperless-filetype-index"
                ]
              ) pt)
              // (nixpkgs.lib.filterAttrs (
                n: _:
                builtins.elem n [
                  "leantime-tidy"
                ]
              ) lt)
              # SentinelOne kills freshly-built binaries during test phase on macOS.
              # Skip nushell tests to avoid build failure on managed Macs.
              // nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") {
                nushell = _prev.nushell.overrideAttrs { doCheck = false; };
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

      # ----- Host definitions ------------------------------------------------
      # Add / remove hosts here; each host points to its NixOS config file.
      nixosHosts = {
        xyz = {
          system = "x86_64-linux";
          configuration = ./hosts/xyz/configuration.nix;
          osIcon = "";
        };
        nux = {
          system = "x86_64-linux";
          configuration = ./hosts/nux/configuration.nix;
          osIcon = "";
        };
        rpi0 = {
          system = "aarch64-linux";
          configuration = ./hosts/rpi0/configuration.nix;
          osIcon = "";
        };
      };

      darwinHosts = {
        mac = {
          system = "aarch64-darwin";
          configuration = ./hosts/mac/configuration.nix;
          osIcon = "";
        };
      };

      # ---- Build NixOS systems ------------------------------------------------
      allNixosSystems = builtins.mapAttrs (
        hostName: hostAttrs:
        nixpkgs.lib.nixosSystem {
          # Provide host-specific specialArgs; pass pkgs for that system
          specialArgs = {
            inherit inputs hostName username;
            configDir = self;
          };
          modules = [
            nixpkgs.nixosModules.readOnlyPkgs
            { nixpkgs.pkgs = pkgsFor.${hostAttrs.system}; }
            hostAttrs.configuration
            sops-nix.nixosModules.sops
          ];
        }
      ) nixosHosts;

      # ---- Build darwin systems ------------------------------------------------
      allDarwinSystems = builtins.mapAttrs (
        hostName: hostAttrs:
        darwin.lib.darwinSystem {
          specialArgs = {
            inherit inputs hostName username;
            configDir = self;
            pkgs = pkgsFor.${hostAttrs.system};
          };
          modules = [
            { nixpkgs.hostPlatform = hostAttrs.system; }
            hostAttrs.configuration
            sops-nix.darwinModules.sops
          ];
        }
      ) darwinHosts;

      # ---- Home Manager configurations ---------------------------------------
      # Use the same unstable pkgs for Home Manager so user modules match packages.
      mkHomeConfiguration =
        system: homeConfigPath: hostName: osIcon:
        home-manager.lib.homeManagerConfiguration {
          # key: make Home Manager use the same pkgsFor (unstable pkgs)
          pkgs = pkgsFor.${system};

          extraSpecialArgs = {
            # make inputs and some helper values available inside HM modules
            inherit
              inputs
              username
              system
              hostName
              osIcon
              ;
            configDir = self;
          };

          # Load the host-specific home config and some shared HM modules
          modules = [
            homeConfigPath
            inputs.nix-colors.homeManagerModules.default
            sops-nix.homeManagerModules.sops
          ];
        };

      homeConfigurations =
        let
          nixosHomeConfigs = lib.mapAttrs' (
            hostName: hostAttrs:
            lib.nameValuePair "${username}-${hostName}" (
              mkHomeConfiguration hostAttrs.system ./users/${username}/linux/${hostName}.nix hostName
                hostAttrs.osIcon
            )
          ) nixosHosts;

          darwinHomeConfigs = lib.mapAttrs' (
            hostName: hostAttrs:
            lib.nameValuePair "${username}-${hostName}" (
              mkHomeConfiguration hostAttrs.system ./users/${username}/darwin/${hostName}.nix hostName
                hostAttrs.osIcon
            )
          ) darwinHosts;
        in
        nixosHomeConfigs // darwinHomeConfigs;

    in
    {
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
        system:
        let
          pkgs = pkgsFor.${system};
        in
        if system == "x86_64-linux" then
          {
            # Cross-compiled U-Boot for Rock Pi 4 (RK3399).
            rpi0-uboot = pkgs.pkgsCross.aarch64-multiplatform.ubootRockPi4;

            # Convenience derivation that collects the two files you need to copy.
            rpi0-uboot-files = pkgs.runCommand "rpi0-uboot-files" { } ''
              set -e
              outdir="$out/share/rockpi4"
              mkdir -p "$outdir"
              cp ${pkgs.pkgsCross.aarch64-multiplatform.ubootRockPi4}/idbloader.img "$outdir/"
              cp ${pkgs.pkgsCross.aarch64-multiplatform.ubootRockPi4}/u-boot.itb "$outdir/"
              echo "Wrote Rock Pi 4 boot files to $outdir"
            '';
          }
        else
          ({ })
      );

    };
}
