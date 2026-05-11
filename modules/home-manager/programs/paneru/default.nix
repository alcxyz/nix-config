# modules/home-manager/programs/paneru/default.nix
# Paneru — niri/PaperWM-style sliding tiling WM for macOS.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:

let
  cfg = config.programs.paneru.managed;
  paneruConfig = "${config.home.homeDirectory}/src/infra/nix-config/users/${username}/configs/paneru/paneru.toml";
  defaultPaneruBin =
    if pkgs.stdenv.hostPlatform.isAarch64 then "/opt/homebrew/bin/paneru" else "/usr/local/bin/paneru";
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
    xdg.configFile."paneru/paneru.toml".source = config.lib.file.mkOutOfStoreSymlink paneruConfig;

    home.activation.removeHomebrewPaneruAgent = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      launchctl bootout "gui/$UID/com.github.karinushka.paneru" 2>/dev/null || true
      launchctl disable "gui/$UID/com.github.karinushka.paneru" 2>/dev/null || true
      rm -f "${config.home.homeDirectory}/Library/LaunchAgents/com.github.karinushka.paneru.plist"
    '';

    launchd.agents.paneru = {
      enable = true;
      config = {
        ProgramArguments = [ cfg.command ];
        RunAtLoad = true;
        KeepAlive = true;
        EnvironmentVariables = {
          PANERU_CONFIG = paneruConfig;
        };
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/paneru.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/paneru.err.log";
      };
    };
  };
}
