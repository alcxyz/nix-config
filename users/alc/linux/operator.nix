{
  inputs,
  pkgs,
  ...
}: {
  imports = [
    ../kubernetes-labs.nix
    inputs.bn-bootstrap.homeManagerModules.boards
    inputs.bn-bootstrap.homeManagerModules.bivrost
    inputs.nix-secrets.homeManagerModules.linuxOperator
    ../../../modules/home-manager/services/nix-package-promotion/default.nix
  ];

  # Bivrost comes from its own flake; bn-bootstrap writes only its Bane NOR
  # catalogue, profiles and sign-in rule (ADR-0090).
  programs.bnBootstrap.bivrost.package = null;
  home.packages = [pkgs.bivrost];
}
