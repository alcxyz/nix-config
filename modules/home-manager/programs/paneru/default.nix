# modules/home-manager/programs/paneru/default.nix
# Paneru — niri/PaperWM-style sliding tiling WM for macOS.
{
  config,
  lib,
  pkgs,
  username,
  configDir,
  ...
}:

let
  cfg = config.programs.paneru.managed;
  defaultPaneruBin =
    if pkgs.stdenv.hostPlatform.isAarch64
    then "/opt/homebrew/bin/paneru"
    else "/usr/local/bin/paneru";
in
{
  options.programs.paneru.managed = {
    enable = lib.mkEnableOption "Manage Paneru configuration and launchd agent";

    command = lib.mkOption {
      type = lib.types.str;
      default = defaultPaneruBin;
      description = "Path to the Paneru binary. Installed by nix-darwin/Homebrew on macOS.";
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile."paneru/paneru.toml".source =
      config.lib.file.mkOutOfStoreSymlink "${configDir}/users/${username}/configs/paneru/paneru.toml";

    launchd.agents.paneru = {
      enable = true;
      config = {
        ProgramArguments = [ cfg.command ];
        RunAtLoad = true;
        KeepAlive = true;
        EnvironmentVariables = {
          PANERU_CONFIG = "${config.xdg.configHome}/paneru/paneru.toml";
        };
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/paneru.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/paneru.err.log";
      };
    };
  };
}
