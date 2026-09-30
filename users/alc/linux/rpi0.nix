# users/alc/linux/rpi0.nix
{
  configDir,
  pkgs,
  ...
}: {
  imports = ["${configDir}/users/alc/linux/embedded.nix"];

  # Diagnostics for rpi0's Bluetooth audio receiver.
  home.packages = [pkgs.bluetuith];
}
