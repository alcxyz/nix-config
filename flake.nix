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
    lib = nixpkgs.lib; # For lib.mapAttrs'

    # No longer need: nixColorsHomeManagerModule = inputs.nix-colors.homeManagerModules.default;

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

    allNixosSystems = builtins.mapAttrs
      (hostName: hostAttrs:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
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
          ];
        }
      )
      nixosHosts;

    allDarwinSystems = builtins.mapAttrs
      (hostName: hostAttrs:
        darwin.lib.darwinSystem {
          system = "aarch64-darwin";
          specialArgs = {
            inherit inputs hostName username;
            configDir = self;
            pkgs = darwinPkgs;
          };
          modules = [
            hostAttrs.configuration
          ];
        }
      )
      darwinHosts;

    # Helper function to create a Home Manager configuration
    # Takes the system string (e.g., "x86_64-linux") and the pkgs for that system
    mkHomeConfiguration = systemForUser: pkgsForUser:
      home-manager.lib.homeManagerConfiguration {
        pkgs = pkgsForUser; # This is the pkgs Home Manager will primarily use
        extraSpecialArgs = {
          inherit inputs username; # username is "alc"
          system = systemForUser; # e.g., "x86_64-linux" or "aarch64-darwin"
          pkgs = pkgsForUser; # Make pkgs available in home.nix via extraSpecialArgs too
        };
        modules = [
          ./users/${username}/home.nix
          inputs.nix-colors.homeManagerModules.default # Inlined here
        ];
      };

  in
  {
  } // allNixosSystems // allDarwinSystems // {
    nixosConfigurations = allNixosSystems;
    darwinConfigurations = allDarwinSystems;

    homeConfigurations =
      let
        # Create home configurations for NixOS hosts
        nixosHomeConfigs = lib.mapAttrs' (hostName: _:
          lib.nameValuePair "${username}-${hostName}" (
            mkHomeConfiguration "x86_64-linux" linuxPkgs
          )
        ) nixosHosts;

        # Create home configurations for Darwin hosts
        darwinHomeConfigs = lib.mapAttrs' (hostName: _:
          lib.nameValuePair "${username}-${hostName}" (
            mkHomeConfiguration "aarch64-darwin" darwinPkgs
          )
        ) darwinHosts;
      in
      nixosHomeConfigs // darwinHomeConfigs; # Merge them

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
  };
}

