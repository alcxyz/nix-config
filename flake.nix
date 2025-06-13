# flake.nix
{
  description = "NixOS and Nix-Darwin configurations for multiple hosts with standalone Home Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    darwin = {
      url = "github:lnl7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:youwen5/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hyprpanel = {
      url = "github:Jas-SinghFSU/HyprPanel";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-colors.url = "github:misterio77/nix-colors";
  };

  outputs = { self, nixpkgs, darwin, home-manager, nix-colors, sops-nix, ... }@inputs:
  let
    username = "alc";
    lib = nixpkgs.lib;

    # Define systems
    supportedSystems = [ "x86_64-linux" "aarch64-darwin" ];

    # Create pkgs for each system
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    pkgsFor = forAllSystems (system: import nixpkgs {
      inherit system;
      config.allowUnfree = true;
      config.cudaSupport = true;
      config.permittedInsecurePackages = [
        "freeimage-3.18.0-unstable-2024-04-18"
        # If other insecure packages pop up, add them here.
      ];
    });

    # Host definitions with new osIcon attribute
    nixosHosts = {
      xyz = {
        system = "x86_64-linux";
        configuration = ./hosts/xyz/configuration.nix;
        osIcon = ""; # NixOS Icon
      };
      nux = {
        system = "x86_64-linux";
        configuration = ./hosts/nux/configuration.nix;
        osIcon = ""; # NixOS Icon
      };
    };

    darwinHosts = {
      mac = {
        system = "aarch64-darwin";
        configuration = ./hosts/mac/configuration.nix;
        osIcon = ""; # Apple Icon
      };
    };

    # Create NixOS systems
    allNixosSystems = builtins.mapAttrs
      (hostName: hostAttrs:
        nixpkgs.lib.nixosSystem {
          system = hostAttrs.system;
          specialArgs = {
            inherit inputs hostName username;
            configDir = self;
            pkgs = pkgsFor.${hostAttrs.system};
          };
          modules = [
            hostAttrs.configuration
            # Add any shared NixOS modules here
            # self.modules.nixos
            sops-nix.nixosModules.sops
          ];
        }
      )
      nixosHosts;

    # Create Darwin systems
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
            # Add any shared Darwin modules here
            # self.modules.darwin
            sops-nix.darwinModules.sops
          ];
        }
      )
      darwinHosts;

    # Create Home Manager configuration
    mkHomeConfiguration = system: homeConfigPath: hostName: osIcon:
      home-manager.lib.homeManagerConfiguration {
        pkgs = pkgsFor.${system};
        extraSpecialArgs = {
          inherit inputs username system hostName osIcon;
          configDir = self;
          pkgs = pkgsFor.${system};
        };
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
              ./users/${username}/home-darwin.nix
              hostName
              hostAttrs.osIcon
          )
        ) darwinHosts;
      in
      nixosHomeConfigs // darwinHomeConfigs;

  in
  {
    # System configurations
    nixosConfigurations = allNixosSystems;
    darwinConfigurations = allDarwinSystems;

    # Home Manager configurations
    homeConfigurations = homeConfigurations;

    # Development shells
    devShells = forAllSystems (system: {
      default = import ./shells/default.nix {
        pkgs = pkgsFor.${system};
      };
    });

    # Shared modules (if you have any)
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

    # Packages (if you want to export any)
    packages = forAllSystems (system: {
      # Add any custom packages here
    });
  };
}
