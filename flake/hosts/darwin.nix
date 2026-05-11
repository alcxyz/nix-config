{
  config,
  inputs,
  lib,
  self,
  ...
}: let
  inherit (config.alc) inventory pkgsFor;
  hostLib = import ./lib.nix {inherit config inputs self;};

  darwinHosts = lib.filterAttrs (_: hostAttrs: hostAttrs.platform == "darwin") inventory.hosts;
  mkDarwinConfiguration = hostName: hostAttrs:
    inputs.darwin.lib.darwinSystem {
      specialArgs =
        (hostLib.specialArgsFor hostName hostAttrs)
        // {
          hostK8sRole = null;
          pkgs = pkgsFor.${hostAttrs.system};
        };
      modules = [
        {nixpkgs.hostPlatform = hostAttrs.system;}
        hostAttrs.configuration
        inputs.sops-nix.darwinModules.sops
      ];
    };

  canonicalDarwinConfigs = builtins.mapAttrs mkDarwinConfiguration darwinHosts;
  aliasDarwinConfigs =
    lib.concatMapAttrs (
      hostName: hostAttrs:
        lib.genAttrs (hostAttrs.aliases or []) (_: canonicalDarwinConfigs.${hostName})
    )
    darwinHosts;
in {
  flake.darwinConfigurations = canonicalDarwinConfigs // aliasDarwinConfigs;
}
