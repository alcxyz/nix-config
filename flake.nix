# flake.nix
{
  description = "NixOS and Nix-Darwin configurations for multiple hosts with \
                standalone Home Manager (all on nixos-unstable)";

  #nixConfig = {
  #  extra-substituters = [
  #    "https://nix-community.cachix.org"
  #    "https://cuda-maintainers.cachix.org"
  #  ];
  #  extra-trusted-public-keys = [
  #    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
  #    "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
  #  ];
  #};

  # ---- Inputs -----------------------------------------------------------
  inputs = {
    # Use unstable as the single source of nixpkgs for everything here.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixpkgs-master.url = "github:NixOS/nixpkgs/master";

    # Secrets repo (private) — flake=false means it won't be treated as a
    # package-providing flake; you probably use it only for fetching sops/age.
    nix-secrets = {
      #url = "path:/home/alc/nix-secrets";
      url = "git+ssh://git@github.com/alcxyz/nix-secrets.git";
      flake = false;
    };

    # Your custom packages flake (callPackage of custom derivations).
    nix-packages = {
      url = "github:alcxyz/nix-packages";
      # follow the same nixpkgs as the main flake so packages are consistent
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # nix-darwin: you may keep a pinned release; left as-is but following
    # the same nixpkgs for consistency.
    darwin = {
      url = "github:nix-darwin/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Use Home Manager master (latest) to ensure compatibility with
    # modern home-manager modules. It follows the same nixpkgs (unstable).
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Third-party flakes and helper flakes you use in configs
    zen-browser = {
      url = "github:youwen5/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Hyprland and related repositories. Keep them as explicit inputs so you
    # can take their flake packages rather than the distro packages.
    hyprland.url = "github:hyprwm/Hyprland";

    hyprland-plugins = {
      url = "github:hyprwm/hyprland-plugins";
      inputs.hyprland.follows = "hyprland";
    };

    hypridle = {
      url = "github:hyprwm/hypridle";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hyprlock = {
      url = "github:hyprwm/hyprlock";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    xremap-flake = {
      url = "github:xremap/nix-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    quickshell = {
      url = "git+https://git.outfoxxed.me/outfoxxed/quickshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dgop = {
      url = "github:AvengeMedia/dgop";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dsearch = {
      url = "github:AvengeMedia/danksearch";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dankMaterialShell = {
      url = "github:AvengeMedia/DankMaterialShell";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.dgop.follows = "dgop";
    };

    opencode = {
      url = "github:sst/opencode";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    goose = {
      url = "github:block/goose";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # color schemes, small extras
    nix-colors.url = "github:misterio77/nix-colors";
  };

  # ---- Outputs ----------------------------------------------------------
  outputs = { self, nixpkgs, nix-packages, nix-secrets, darwin, home-manager, nix-colors, sops-nix, ... }@inputs:
  let
    # Basic identity values
    username = "alc";
    lib = nixpkgs.lib;

    # Systems we support in this flake (add more if needed)
    supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];

    # genAttrs helper to create per-system pkgs attrs
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

    # Create a pkgs set for each supported system using the same nixpkgs-unstable
      #pkgsFor = forAllSystems (system:
      #  import nixpkgs {
      #    inherit system;
      #    # Allow unfree if you use browser binaries or such
      #    config.allowUnfree = true;
      #    # GPU / CUDA support as needed
      #    # config.cudaSupport = true;
      #    # If you need to permit specific insecure packages, list them here
      #    config.permittedInsecurePackages = [
      #      "freeimage-3.18.0-unstable-2024-04-18" # used by Sunshine
      #    ];
      #  });

    pkgsFor = forAllSystems (system:
      let
        overlays = [
          (final: prev: {
            ndrop = nix-packages.packages.${final.system}.ndrop;
            carapace = nix-packages.packages.${final.system}.carapace;
            carapace-bridge = nix-packages.packages.${final.system}.carapace-bridge;
            zfs-auto-unlock = nix-packages.packages.${final.system}.zfs-auto-unlock;
            pihole-sync = nix-packages.packages.${final.system}.pihole-sync;
          })
        ];

        # Base: unstable pkgs (what you use everywhere now)
        pkgsUnstable = import nixpkgs {
          inherit system overlays;
          config.allowUnfree = true;
          config.allowUnsupportedSystem = true;
          config.permittedInsecurePackages = [
            "freeimage-3.18.0-unstable-2024-04-18"
          ];
        };

        # Only import master for Linux, because that’s where MongoDB is needed
        pkgsMaster =
          if system == "x86_64-linux" then
            import inputs.nixpkgs-master {
              inherit system;
              config.allowUnfree = true;
            }
          else
            pkgsUnstable;
      in
      # Use unstable everywhere, but override mongodb on Linux with the master version
      pkgsUnstable // (if system == "x86_64-linux" then {
        mongodb = pkgsMaster.mongodb;
      } else {})
    );

    # ----- Host definitions ------------------------------------------------
    # Add / remove hosts here; each host points to its NixOS config file.
    nixosHosts = {
      xyz = {
        system = "x86_64-linux";
        configuration = ./hosts/xyz/configuration.nix;
        osIcon = ""; # NixOS glyph for prompts
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
    allNixosSystems = builtins.mapAttrs
      (hostName: hostAttrs:
        nixpkgs.lib.nixosSystem {
          system = hostAttrs.system;
          # Provide host-specific specialArgs; pass pkgs for that system
          specialArgs = {
            inherit inputs hostName username;
            configDir = self;
            pkgs = pkgsFor.${hostAttrs.system};
          };
          modules = [
            hostAttrs.configuration
            # sops-nix module used for secrets handling system-wide
            sops-nix.nixosModules.sops
            # add shared NixOS modules here if needed
          ];
        }
      )
      nixosHosts;

    # ---- Build darwin systems ------------------------------------------------
    allDarwinSystems = builtins.mapAttrs
      (hostName: hostAttrs:
        darwin.lib.darwinSystem {
          system = hostAttrs.system;
          specialArgs = {
            inherit inputs hostName username;
            configDir = self;
            pkgs = pkgsFor.${hostAttrs.system};
          };
          modules = [
            hostAttrs.configuration
            sops-nix.darwinModules.sops
            # add shared darwin modules here
          ];
        }
      )
      darwinHosts;

    # ---- Home Manager configurations ---------------------------------------
    # Use the same unstable pkgs for Home Manager so user modules match packages.
    mkHomeConfiguration = system: homeConfigPath: hostName: osIcon:
      home-manager.lib.homeManagerConfiguration {
        # key: make Home Manager use the same pkgsFor (unstable pkgs)
        pkgs = pkgsFor.${system};

        extraSpecialArgs = {
          # make inputs and some helper values available inside HM modules
          inherit inputs username system hostName osIcon;
          configDir = self;
          pkgs = pkgsFor.${system};
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
        nixosHomeConfigs = lib.mapAttrs' (hostName: hostAttrs:
          lib.nameValuePair "${username}-${hostName}" (
            mkHomeConfiguration
              hostAttrs.system
              ./users/${username}/linux/${hostName}.nix
              hostName
              hostAttrs.osIcon
          )
        ) nixosHosts;

        darwinHomeConfigs = lib.mapAttrs' (hostName: hostAttrs:
          lib.nameValuePair "${username}-${hostName}" (
            mkHomeConfiguration
              hostAttrs.system
              ./users/${username}/darwin/${hostName}.nix
              hostName
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

    # Shared modules bundles (if present) are exposed under self.modules.*
    modules = {
      nixos = if builtins.pathExists ./modules/nixos/default.nix
              then import ./modules/nixos/default.nix
              else {};
      darwin = if builtins.pathExists ./modules/darwin/default.nix
               then import ./modules/darwin/default.nix
               else {};
      home-manager = if builtins.pathExists ./modules/home-manager/default.nix
                     then import ./modules/home-manager/default.nix
                     else {};
    };

    # Packages: add cross-build helpers for Rock Pi 4 (build on xyz).
    packages = forAllSystems (system:
      let
        pkgs = pkgsFor.${system};
      in
      if system == "x86_64-linux" then {
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
      } else (
        {}
      )
    );

  };
}
