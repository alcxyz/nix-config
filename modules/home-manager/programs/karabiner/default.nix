# modules/home-manager/programs/karabiner/default.nix
#
# Karabiner Elements — keyboard remapping for macOS.
# Config is a static JSON file maintained in users/alc/configs/karabiner/,
# symlinked here from the flake source, so edits apply on the next Home Manager
# switch.
# See ADR-0011 for context on why Karabiner instead of kanata.
{
  config,
  lib,
  username,
  configDir,
  ...
}:
with lib; let
  cfg = config.programs.karabiner.managed;
in {
  options.programs.karabiner.managed = {
    enable = mkEnableOption "Manage Karabiner Elements configuration";
  };

  config = mkIf cfg.enable {
    xdg.configFile."karabiner/karabiner.json".source =
      config.lib.file.mkOutOfStoreSymlink
      "${configDir}/users/${username}/configs/karabiner/karabiner.json";
  };
}
