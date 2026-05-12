{
  config,
  pkgs,
  inputs,
  username,
  hostRole,
  configDir,
  lib,
  ...
}: let
  pkgsets = import "${configDir}/modules/shared/pkgsets.nix" {
    inherit pkgs inputs;
  };
in {
  # ==================== Imports ====================
  #imports = [
  #];

  # ==================== Users ====================
  users.users.${username}.extraGroups = [
  ];

  # ==================== System Packages ====================
  environment.systemPackages = pkgsets.system.${hostRole.systemPackageSet};

  # ==================== Services ====================
  services.xserver.enable = false;

  # ==================== Networking ====================
  networking.resolvconf.enable = true;
}
