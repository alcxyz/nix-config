# users/alc/linux/rpi0.nix
{
  inputs,
  configDir,
  pkgs,
  hostRole,
  ...
}: let
  pkgsets = import "${configDir}/modules/shared/pkgsets.nix" {
    inherit pkgs inputs;
  };
in {
  imports = ["${configDir}/users/alc/linux/operator.nix"];

  home.packages = pkgsets.home.${hostRole.homePackageSet};
}
