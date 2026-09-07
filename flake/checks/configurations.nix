{
  self,
  pkgs,
}: let
  # Force deployment derivations without adding their closures as build
  # dependencies. Custom Home Manager/Darwin outputs are otherwise skipped
  # by the standard flake output schema checks. Include aliases as exported.
  configurations = {
    nixos = builtins.mapAttrs (_: host: host.config.system.build.toplevel.drvPath) self.nixosConfigurations;
    home = builtins.mapAttrs (_: home: home.activationPackage.drvPath) self.homeConfigurations;
    darwin = builtins.mapAttrs (_: host: host.system.drvPath) self.darwinConfigurations;
  };
in {
  configuration-evaluation = builtins.deepSeq configurations (
    pkgs.runCommand "configuration-evaluation" {} ''
      touch "$out"
    ''
  );
}
