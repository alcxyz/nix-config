{
  config,
  inputs,
  lib,
  self,
  ...
}: let
  inherit (config.alc) inventory pkgsFor;
  hostLib = import ./lib.nix {inherit config inputs self;};

  nixosHosts = lib.filterAttrs (_: hostAttrs: hostAttrs.platform == "nixos") inventory.hosts;
in {
  flake.nixosConfigurations =
    builtins.mapAttrs (
      hostName: hostAttrs:
        inputs.nixpkgs.lib.nixosSystem {
          specialArgs = hostLib.specialArgsFor hostName hostAttrs;
          modules =
            [
              inputs.nixpkgs.nixosModules.readOnlyPkgs
              {nixpkgs.pkgs = pkgsFor.${hostAttrs.system};}
              hostAttrs.configuration
              inputs.nix-secrets.nixosModules.beszelAgentDefaults
              inputs.nix-secrets.nixosModules.forgejoActionsRunnerDefaults
              inputs.nix-secrets.nixosModules.forgeMirrorDefaults
              inputs.nix-secrets.nixosModules.storageBackupPolicy
              inputs.sops-nix.nixosModules.sops
            ]
            ++ lib.optional (inputs.nix-secrets.nixosModules ? operatorLogin)
            inputs.nix-secrets.nixosModules.operatorLogin;
        }
    )
    nixosHosts;
}
