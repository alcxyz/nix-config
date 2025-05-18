# flake.nix
{
  description = "NixOS and Nix-Darwin configurations for multiple hosts with standalone Home Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    darwin = {
      url = "github:lnl7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
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
    # Define specific package sets for your fixed architectures
    linuxPkgs = import nixpkgs {
      system = "x86_64-linux";
      config.allowUnfree = true;
    };
    darwinPkgs = import nixpkgs {
      system = "aarch64-darwin";
      config.allowUnfree = true;
    };

    supportedSystems = [ "x86_64-linux" "aarch64-darwin" ];

    nixosHosts = {
      xyz = { configuration = ./hosts/xyz/configuration.nix; };
      nuc = { configuration = ./hosts/nuc/configuration.nix; };
    };

    darwinHosts = {
      mac = { configuration = ./hosts/mac/configuration.nix; };
    };

    # Define all NixOS system configurations
    allNixosSystems = builtins.mapAttrs
      (hostName: hostAttrs:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux"; # Fixed system for NixOS hosts
          specialArgs = {
            inherit inputs hostName username;
            configDir = self;
            pkgs = linuxPkgs;
          };
          modules = [
            { nixpkgs.system = "x86_64-linux"; }
            { nixpkgs.pkgs = linuxPkgs; }
            hostAttrs.configuration
            self.modules.nixos
            # home-manager.nixosModules.home-manager
          ];
        }
      )
      nixosHosts;

    # Define all Darwin system configurations
    allDarwinSystems = builtins.mapAttrs
      (hostName: hostAttrs:
        darwin.lib.darwinSystem {
          system = "aarch64-darwin"; # Fixed system for Darwin hosts
          specialArgs = {
            inherit inputs hostName username;
            configDir = self;
            pkgs = darwinPkgs;
          };
          modules = [
            hostAttrs.configuration
            # home-manager.darwinModules.home-manager
          ];
        }
      )
      darwinHosts;

  in # This is the main output set
  {
    # Merge NixOS and Darwin systems directly into outputs
    # This makes .#xyz, .#nuc, .#mac directly available
  } // allNixosSystems // allDarwinSystems // {
    # Keep the grouped configurations as well
    nixosConfigurations = allNixosSystems;
    darwinConfigurations = allDarwinSystems;

    homeConfigurations = {
      "${username}" = # This is the "alc" attribute
        let
          currentSystem = builtins.currentSystem;
          currentPkgs = if currentSystem == "x86_64-linux" then linuxPkgs
                        else if currentSystem == "aarch64-darwin" then darwinPkgs
                        else throw "Unsupported system for home-manager: ${currentSystem}";
        in
        home-manager.lib.homeManagerConfiguration {
          pkgs = currentPkgs;
          extraSpecialArgs = {
            inherit inputs username;
            system = currentSystem;
            pkgs = currentPkgs;
          };
          modules = [
            ./users/${username}/home.nix
            nix-colors.homeManagerModules.nix-colors
          ];
        };
    }; # End of the "alc" configuration block

    devShells = builtins.listToAttrs (map (system: {
      name = system;
      value = import ./shells/default.nix { 
        pkgs = if system == "x86_64-linux" then linuxPkgs 
               else if system == "aarch64-darwin" then darwinPkgs 
               else throw "Unsupported system for devShell: ${system}"; 
      };
    }) supportedSystems);
    
    modules = {
      nixos = import ./modules/nixos/default.nix;
      home-manager = if builtins.pathExists ./modules/home-manager/default.nix
             then import ./modules/home-manager/default.nix
             else {}; 
    };

    # The explicit aliases below are no longer needed
    # xyz = self.nixosConfigurations.xyz;
    # nuc = self.nixosConfigurations.nuc;
    # mac = self.darwinConfigurations.mac;
  };
}
