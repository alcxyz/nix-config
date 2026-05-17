{
  config,
  lib,
  pkgs,
  username,
  configDir,
  ...
}: let
  cfg = config.programs.authorized-video-download;
  configPath = "${configDir}/users/${username}/configs/authorized-video-download/config";
in {
  options.programs.authorized-video-download = {
    enable = lib.mkEnableOption "authorized video download TUI";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.authorized-video-download;
      description = "Package providing the authorized-video-download TUI.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [cfg.package];

    # Symlink the user-editable config directly to the repo checkout, matching
    # the Hyprland config pattern.
    xdg.configFile."authorized-video-download/config".source =
      config.lib.file.mkOutOfStoreSymlink configPath;
  };
}
