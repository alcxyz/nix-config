{inputs, ...}: {
  imports = [
    inputs.nix-secrets.homeManagerModules.linuxOperator
  ];
}
