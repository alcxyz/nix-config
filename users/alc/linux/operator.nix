{inputs, ...}: {
  imports = [
    ../kubernetes-labs.nix
    inputs.nix-secrets.homeManagerModules.linuxOperator
  ];
}
