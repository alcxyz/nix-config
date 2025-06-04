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
      url = "github:0xc000022070/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    
    hyprpanel = {
      url = "github:Jas-SinghFSU/HyprPanel";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    
    nix-colors.url = "github:misterio77/nix-colors";
  };

  outputs = { self, nixpkgs, darwin, home-manager, nix-colors, ... }@inputs:
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

    # Host definitions
    nixosHosts = {
      xyz = { 
        system = "x86_64-linux";
        configuration = ./hosts/xyz/configuration.nix; 
      };
      nuc = { 
        system = "x86_64-linux";
        configuration = ./hosts/nuc/configuration.nix; 
      };
    };

    darwinHosts = {
      mac = { 
        system = "aarch64-darwin";
        configuration = ./hosts/mac/configuration.nix; 
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
          ];
        }
      )
      darwinHosts;

    # Helper function to create Home Manager configuration
    mkHomeConfiguration = system: homeConfigPath:
      home-manager.lib.homeManagerConfiguration {
        pkgs = pkgsFor.${system};
        extraSpecialArgs = {
          inherit inputs username system;
          configDir = self;
          pkgs = pkgsFor.${system};
        };
        modules = [
          homeConfigPath
          inputs.nix-colors.homeManagerModules.default
          # Add any shared home-manager modules here
          # self.modules.home-manager
        ];
      };

    # Create home configurations
    homeConfigurations =
      let
        # NixOS home configs
        nixosHomeConfigs = lib.mapAttrs' (hostName: hostAttrs:
          lib.nameValuePair "${username}-${hostName}" (
            mkHomeConfiguration hostAttrs.system ./users/${username}/home-linux.nix
          )
        ) nixosHosts;

        # Darwin home configs  
        darwinHomeConfigs = lib.mapAttrs' (hostName: hostAttrs:
          lib.nameValuePair "${username}-${hostName}" (
            mkHomeConfiguration hostAttrs.system ./users/${username}/home-darwin.nix
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
