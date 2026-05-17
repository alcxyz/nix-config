{
  config,
  lib,
  pkgs,
  username,
  configDir,
  ...
}: let
  cfg = config.programs.vidown;
  configPath = "${configDir}/users/${username}/configs/vidown/config";
in {
  options.programs.vidown = {
    enable = lib.mkEnableOption "vidown video download TUI";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.vidown;
      description = "Package providing the vidown TUI.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [cfg.package];

    # Symlink the user-editable config directly to the repo checkout, matching
    # the Hyprland config pattern.
    xdg.configFile."vidown/config".source =
      config.lib.file.mkOutOfStoreSymlink configPath;
  };
}
