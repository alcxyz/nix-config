{
  config,
  inputs,
  lib,
  self,
  ...
}: let
  inherit (config.alc) inventory pkgsFor username;
  hostLib = import ./lib.nix {inherit config inputs self;};

  homeManagerEnabled = hostAttrs: hostAttrs.homeManager or true;
  nixosHosts =
    lib.filterAttrs
    (_: hostAttrs: hostAttrs.platform == "nixos" && homeManagerEnabled hostAttrs)
    inventory.hosts;
  darwinHosts =
    lib.filterAttrs
    (_: hostAttrs: hostAttrs.platform == "darwin" && homeManagerEnabled hostAttrs)
    inventory.hosts;

  mkHomeConfiguration = hostName: hostAttrs: homeConfigPath:
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = pkgsFor.${hostAttrs.system};

      extraSpecialArgs =
        (hostLib.specialArgsFor hostName hostAttrs)
        // {
          system = hostAttrs.system;
          osIcon = hostAttrs.osIcon;
        };

      modules = [
        homeConfigPath
        inputs.bn-bootstrap.homeManagerModules.bullet
        inputs.nix-colors.homeManagerModules.default
        inputs.sops-nix.homeManagerModules.sops
      ];
    };

  nixosHomeConfigs =
    lib.mapAttrs' (
      hostName: hostAttrs:
        lib.nameValuePair "${username}-${hostName}" (
          mkHomeConfiguration hostName hostAttrs ../../users/${username}/linux/${hostName}.nix
        )
    )
    nixosHosts;

  darwinHomeConfigs =
    lib.mapAttrs' (
      hostName: hostAttrs:
        lib.nameValuePair "${username}-${hostName}" (
          mkHomeConfiguration hostName hostAttrs ../../users/${username}/darwin/${hostName}.nix
        )
    )
    darwinHosts;

  darwinHomeAliases =
    lib.concatMapAttrs (
      hostName: hostAttrs:
        lib.mapAttrs' (
          alias: _:
            lib.nameValuePair "${username}-${alias}" darwinHomeConfigs."${username}-${hostName}"
        )
        (lib.genAttrs (hostAttrs.aliases or []) (_: null))
    )
    darwinHosts;
in {
  flake.homeConfigurations = nixosHomeConfigs // darwinHomeConfigs // darwinHomeAliases;
}
