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
    supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

    pkgsFor = arch: import nixpkgs {
      system = arch;
      config.allowUnfree = true;
    };

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

  in
  {
    nixosConfigurations = builtins.mapAttrs
      (hostName: hostAttrs:
        nixpkgs.lib.nixosSystem {
          inherit (hostAttrs) system;
          specialArgs = {
            inherit inputs pkgsFor hostName username;
            configDir = self;
            pkgs = pkgsFor hostAttrs.system;
          };
          modules = [
            { nixpkgs.system = hostAttrs.system; }
            { nixpkgs.pkgs = pkgsFor hostAttrs.system; }
            
            # inputs.nixpkgs.nixosModules.readOnlyPkgs # Temporarily removed for diagnostics
            
            hostAttrs.configuration
            self.modules.nixos
            # nix-colors.nixosModules.nix-colors
            home-manager.nixosModules.home-manager
          ];
        }
      )
      nixosHosts;

    darwinConfigurations = builtins.mapAttrs
      (hostName: hostAttrs:
        darwin.lib.darwinSystem {
          inherit (hostAttrs) system;
          specialArgs = {
            inherit inputs pkgsFor hostName username;
            configDir = self;
            pkgs = pkgsFor hostAttrs.system;
          };
          modules = [
            hostAttrs.configuration
            # self.modules.nixos 
            # home-manager.darwinModules.home-manager
          ];
        }
      )
      darwinHosts;

    homeConfigurations.${username} = home-manager.lib.homeManagerConfiguration {
      pkgs = pkgsFor builtins.currentSystem;
      extraSpecialArgs = {
        inherit inputs username pkgsFor;
      };
      modules = [
        ./users/${username}/home.nix
        nix-colors.homeManagerModules.nix-colors
      ];
    };

    /* devShells = builtins.listToAttrs (map (system: {
      name = system;
      value = import ./shells/default.nix { pkgs = pkgsFor system; };
    }) supportedSystems); */
    
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
