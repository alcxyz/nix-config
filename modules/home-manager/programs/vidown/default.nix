{
  config,
  lib,
  pkgs,
  username,
  configDir,
  ...
}: let
  cfg = config.programs.vidown;
  publicConfigPath = "${configDir}/users/${username}/configs/vidown/config";
  privateConfigPath = "${config.home.homeDirectory}/src/infra/nix-secrets/users/${username}/configs/vidown/config";
  configPath =
    if builtins.pathExists privateConfigPath
    then privateConfigPath
    else publicConfigPath;
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

    # Keep this mutable: editing the local nix-secrets checkout updates vidown
    # without needing a flake input bump.
    xdg.configFile."vidown/config".source =
      config.lib.file.mkOutOfStoreSymlink configPath;
  };
}
