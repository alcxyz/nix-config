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

    # Your actual supported systems based on host configurations
    supportedSystems = [ "x86_64-linux" "aarch64-darwin" ];

    # Host definitions - system attribute is now implicit
    nixosHosts = {
      xyz = { configuration = ./hosts/xyz/configuration.nix; };
      nuc = { configuration = ./hosts/nuc/configuration.nix; };
    };

    darwinHosts = {
      mac = { configuration = ./hosts/mac/configuration.nix; };
    };

  in
  {
    nixosConfigurations = builtins.mapAttrs
      (hostName: hostAttrs:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux"; # Fixed system for NixOS hosts
          specialArgs = {
            inherit inputs hostName username;
            configDir = self;
            pkgs = linuxPkgs; # Use pre-defined linuxPkgs
            # pkgsFor is no longer needed here
          };
          modules = [
            { nixpkgs.system = "x86_64-linux"; }
            { nixpkgs.pkgs = linuxPkgs; }
            hostAttrs.configuration
            self.modules.nixos
            # home-manager.nixosModules.home-manager # You might want to add this for NixOS integration
          ];
        }
      )
      nixosHosts;

    darwinConfigurations = builtins.mapAttrs
      (hostName: hostAttrs:
        darwin.lib.darwinSystem {
          system = "aarch64-darwin"; # Fixed system for Darwin hosts
          specialArgs = {
            inherit inputs hostName username;
            configDir = self;
            pkgs = darwinPkgs; # Use pre-defined darwinPkgs
            # pkgsFor is no longer needed here
          };
          modules = [
            hostAttrs.configuration
            # self.modules.nixos # This is NixOS specific, usually not for Darwin
            # home-manager.darwinModules.home-manager # You might want to add this for Darwin integration
          ];
        }
      )
      darwinHosts;

    homeConfigurations =
    let
      currentSystem = builtins.currentSystem;
      # Determine pkgs based on the current system
      currentPkgs = if currentSystem == "x86_64-linux" then linuxPkgs
                      else if currentSystem == "aarch64-darwin" then darwinPkgs
                      else throw "Unsupported system for home-manager: ${currentSystem}";
    in
    {
      "${username}" = home-manager.lib.homeManagerConfiguration {
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
    };

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

    # === Top-level aliases for building systems ===
    xyz = self.nixosConfigurations.xyz.config.system.build.toplevel;
    nuc = self.nixosConfigurations.nuc.config.system.build.toplevel;
    mac = self.darwinConfigurations.mac.config.system.build.toplevel;
  };
}
