# users/alc/linux/nex.nix
{
  inputs,
  configDir,
  pkgs,
  ...
}: let
  pkgsets = import "${configDir}/modules/nixos/common/pkgsets.nix" {
    inherit pkgs inputs;
  };
in {
  imports = ["${configDir}/users/alc/linux/common.nix"];

  home.packages = pkgsets.home.nuc;
}
