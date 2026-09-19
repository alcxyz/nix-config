{inputs, ...}: {
  imports = [
    ../kubernetes-labs.nix
    inputs.bn-bootstrap.homeManagerModules.bullet
    inputs.nix-secrets.homeManagerModules.linuxOperator
    ../../../modules/home-manager/services/nix-package-promotion/default.nix
  ];
}
