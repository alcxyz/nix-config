{
  inputs,
  pkgs,
  ...
}: {
  imports = [
    ../kubernetes-labs.nix
    inputs.work.homeManagerModules.backlog
    inputs.work.homeManagerModules.boards
    inputs.work.homeManagerModules.bivrost
    inputs.teams-chat.homeManagerModules.default
    inputs.portal-receipts.homeManagerModules.default
    inputs.nix-secrets.homeManagerModules.linuxOperator
    ../../../modules/home-manager/services/nix-package-promotion/default.nix
  ];

  # Bivrost comes from its own flake; the work flake writes only its work
  # catalogue, profiles and sign-in rule (ADR-0090).
  programs.work.bivrost.package = null;
  home.packages = [pkgs.bivrost];
}
