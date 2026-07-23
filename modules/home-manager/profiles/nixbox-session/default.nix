{
  configDir,
  lib,
  ...
}: {
  imports = ["${configDir}/modules/home-manager/services/waynergy/default.nix"];

  # Keep the Synergy input path identical across Nixbox clients. Host modules
  # supply only their stable screen name and, when necessary, server address.
  services.waynergy = {
    enable = lib.mkDefault true;
    sourceKeyboard = lib.mkDefault "mac";
    backend = lib.mkDefault "wlr";
    requireLanAddress = lib.mkDefault true;
    useFocusedMonitorGeometry = lib.mkDefault true;
  };
}
