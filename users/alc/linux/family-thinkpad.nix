# users/alc/linux/family-thinkpad.nix
{
  pkgs,
  inputs,
  configDir,
  hostRole,
  ...
}: let
  pkgsets = import "${configDir}/modules/shared/pkgsets.nix" {
    inherit pkgs inputs;
  };
in {
  imports = [
    "${configDir}/modules/home-manager/programs/kubernetes/default.nix"
  ];

  home.username = "alc";
  home.homeDirectory = "/home/alc";
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  home.packages = pkgsets.home.${hostRole.homePackageSet};

  home.sessionVariables = {
    FLAKE = configDir;
  };
}
