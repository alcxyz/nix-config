{
  self,
  inputs,
  nixpkgs,
  darwin,
  home-manager,
  sops-nix,
  pkgsFor,
  inventory,
  username,
  ...
}: let
  lib = nixpkgs.lib;
  inventoryHosts = inventory.hosts;

  # Add / remove hosts in inventory.nix.
  nixosHosts = lib.filterAttrs (_: hostAttrs: hostAttrs.platform == "nixos") inventoryHosts;
  darwinHosts = lib.filterAttrs (_: hostAttrs: hostAttrs.platform == "darwin") inventoryHosts;

  hostK8sRoleFor = hostAttrs:
    if hostAttrs.k8sRole == null
    then null
    else inventory.k8sRoles.${hostAttrs.k8sRole};

  commonSpecialArgs = hostName: hostAttrs: {
    inherit inputs inventory hostName username;
    configDir = self;
    hostInventory = hostAttrs;
    hostRole = inventory.roles.${hostAttrs.role};
    hostK8sRole = hostK8sRoleFor hostAttrs;
  };

  nixosConfigurations =
    builtins.mapAttrs (
      hostName: hostAttrs:
        nixpkgs.lib.nixosSystem {
          specialArgs = commonSpecialArgs hostName hostAttrs;
          modules = [
            nixpkgs.nixosModules.readOnlyPkgs
            {nixpkgs.pkgs = pkgsFor.${hostAttrs.system};}
            hostAttrs.configuration
            sops-nix.nixosModules.sops
          ];
        }
    )
    nixosHosts;

  darwinConfigurations =
    builtins.mapAttrs (
      hostName: hostAttrs:
        darwin.lib.darwinSystem {
          specialArgs =
            (commonSpecialArgs hostName hostAttrs)
            // {
              hostK8sRole = null;
              pkgs = pkgsFor.${hostAttrs.system};
            };
          modules = [
            {nixpkgs.hostPlatform = hostAttrs.system;}
            hostAttrs.configuration
            sops-nix.darwinModules.sops
          ];
        }
    )
    darwinHosts;

  mkHomeConfiguration = hostName: hostAttrs: homeConfigPath:
    home-manager.lib.homeManagerConfiguration {
      pkgs = pkgsFor.${hostAttrs.system};

      extraSpecialArgs =
        (commonSpecialArgs hostName hostAttrs)
        // {
          system = hostAttrs.system;
          osIcon = hostAttrs.osIcon;
        };

      modules = [
        homeConfigPath
        inputs.nix-colors.homeManagerModules.default
        sops-nix.homeManagerModules.sops
      ];
    };

  nixosHomeConfigs =
    lib.mapAttrs' (
      hostName: hostAttrs:
        lib.nameValuePair "${username}-${hostName}" (
          mkHomeConfiguration hostName hostAttrs ../users/${username}/linux/${hostName}.nix
        )
    )
    nixosHosts;

  darwinHomeConfigs =
    lib.mapAttrs' (
      hostName: hostAttrs:
        lib.nameValuePair "${username}-${hostName}" (
          mkHomeConfiguration hostName hostAttrs ../users/${username}/darwin/${hostName}.nix
        )
    )
    darwinHosts;
in {
  flake = {
    inherit nixosConfigurations darwinConfigurations;
    homeConfigurations = nixosHomeConfigs // darwinHomeConfigs;
  };
}
