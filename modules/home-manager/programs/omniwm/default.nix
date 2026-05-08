# modules/home-manager/programs/omniwm/default.nix
# OmniWM — niri-style scrolling tiling WM for macOS
# Installed via Homebrew cask (BarutSRB/tap); config managed here.
{ config, lib, inputs, username, configDir, ... }:
with lib;

let
  cfg = config.programs.omniwm.managed;
in {
  options.programs.omniwm.managed = {
    enable = mkEnableOption "Manage OmniWM configuration";
  };

  config = mkIf cfg.enable {
    # Symlink settings.json so edits in the repo are live without rebuild
    xdg.configFile."omniwm/settings.json".source = config.lib.file.mkOutOfStoreSymlink
      "${configDir}/users/${username}/configs/omniwm/settings.json";
  };
}
