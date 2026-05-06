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
in {
  flake.darwinConfigurations =
    builtins.mapAttrs (
      hostName: hostAttrs:
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
        }
    )
    darwinHosts;
}
