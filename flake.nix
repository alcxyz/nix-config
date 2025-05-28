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

    # Helper function to create a Home Manager configuration
    mkHomeConfiguration = systemForUser: pkgsForUser: homeConfigPath:
      home-manager.lib.homeManagerConfiguration {
        pkgs = pkgsForUser;
        extraSpecialArgs = {
          inherit inputs username systemForUser;
          configDir = self;
          pkgs = pkgsForUser;
        };
        modules = [
          homeConfigPath
          inputs.nix-colors.homeManagerModules.default
        ];
      };

  in
  {
  } // allNixosSystems // allDarwinSystems // {
    nixosConfigurations = allNixosSystems;
    darwinConfigurations = allDarwinSystems;

    homeConfigurations =
      let
        nixosHomeConfigs = lib.mapAttrs' (hostName: _:
          lib.nameValuePair "${username}-${hostName}" (
            mkHomeConfiguration "x86_64-linux" linuxPkgs ./users/${username}/home-linux.nix
          )
        ) nixosHosts;

        darwinHomeConfigs = lib.mapAttrs' (hostName: _:
          lib.nameValuePair "${username}-${hostName}" (
            mkHomeConfiguration "aarch64-darwin" darwinPkgs ./users/${username}/home-darwin.nix
          )
        ) darwinHosts;
      in
      nixosHomeConfigs // darwinHomeConfigs;

    devShells = builtins.listToAttrs (map (system: {
      name = system;
      value = {
        default = import ./shells/default.nix {
          pkgs = if system == "x86_64-linux" then linuxPkgs
                 else if system == "aarch64-darwin" then darwinPkgs
                 else throw "Unsupported system for devShell: ${system}";
        };
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
