# flake.nix
{
  description = "NixOS and Nix-Darwin configurations for multiple hosts with standalone Home Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    darwin = {
      url = "github:lnl7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs"; # Corrected: darwin follows nixpkgs from its own inputs
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs"; # Corrected: home-manager follows nixpkgs from its own inputs
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
            configDir = self; # 'self' here refers to the flake's outputs, its path is used
            pkgs = pkgsFor hostAttrs.system;
          };
          modules = [
            hostAttrs.configuration # Host-specific configuration (e.g., hosts/xyz/configuration.nix)
            self.modules.system # Shared system module (modules/system/default.nix)
            nix-colors.nixosModules.nix-colors
            # home-manager.nixosModules.home-manager # Add this if you want NixOS to manage HM for this host
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
            # self.modules.system # If you have parts of it compatible with Darwin
            # nix-colors.nixosModules.nix-colors # If it has Darwin support
            # home-manager.darwinModules.home-manager # For Darwin-managed HM
          ];
        }
      )
      darwinHosts;

    homeConfigurations.${username} = home-manager.lib.homeManagerConfiguration {
      pkgs = pkgsFor.${builtins.currentSystem}; # pkgs for the system evaluating the flake
      extraSpecialArgs = {
        inherit inputs username pkgsFor;
        # pkgs = pkgsFor.${builtins.currentSystem}; # Redundant if top-level pkgs is set this way
                                                 # but harmless. Ensures 'pkgs' arg in modules is this.
      };
      modules = [
        ./users/${username}/home.nix # Path relative to flake root
        nix-colors.homeManagerModules.nix-colors
        # { programs.home-manager.enable = true; } # Already in your users/alc/home.nix
      ];
    };

    devShells = builtins.listToAttrs (map (system: {
      name = system;
      value = import ./shells/default.nix { pkgs = pkgsFor system; };
    }) supportedSystems);

    modules = {
      # This makes self.modules.system refer to the actual module definition
      system = import ./modules/system/default.nix;

      # Assuming modules/home/default.nix is your main entry point for shared HM modules
      # If not, adjust or remove.
      home = if builtins.pathExists ./modules/home/default.nix
             then import ./modules/home/default.nix
             else {}; # Placeholder if no central home module aggregator
    };
  };
}
