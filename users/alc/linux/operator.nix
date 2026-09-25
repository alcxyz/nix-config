{inputs, ...}: {
  imports = [
    ../kubernetes-labs.nix
    inputs.bn-bootstrap.homeManagerModules.boards
    inputs.bn-bootstrap.homeManagerModules.bivrost
    inputs.nix-secrets.homeManagerModules.linuxOperator
    ../../../modules/home-manager/services/nix-package-promotion/default.nix
  ];
}
