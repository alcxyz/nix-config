# users/alc/linux/nux.nix
{
  inputs,
  configDir,
  pkgs,
  hostRole,
  ...
}: let
  pkgsets = import "${configDir}/modules/nixos/common/pkgsets.nix" {
    inherit pkgs inputs;
  };
in {
  # Import the common Linux configuration.
  imports = ["${configDir}/users/alc/linux/common.nix"];

  home.packages = pkgsets.home.${hostRole.homePackageSet};
}
