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
              ({config, ...}: {
                assertions = [
                  {
                    assertion = config.services.k3s.enable == ((hostAttrs.k8sRole or null) != null);
                    message = "${hostName}: k3s enablement must agree with inventory membership.";
                  }
                ];
              })
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
    nixosHosts
    // {
      # Explicit boot targets for the separately scheduled bulk disk move.
      # Ordinary xyz/xev outputs retain current ownership until finalization.
      xyz-tank-on-xev = self.nixosConfigurations.xyz.extendModules {
        specialArgs.tankMigrationBase = self.nixosConfigurations.xyz.config;
        modules = ["${inputs.nix-secrets}/modules/nixos/xyz-tank-remote.nix"];
      };
      xev-tank-owner = self.nixosConfigurations.xev.extendModules {
        modules = ["${inputs.nix-secrets}/modules/nixos/xev-tank-owner.nix"];
      };
    };
}
