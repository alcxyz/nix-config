{
  config,
  lib,
  pkgs,
  username,
  configDir,
  inputs,
  ...
}: let
  cfg = config.programs.vidown;
  publicConfigPath = "${configDir}/users/${username}/configs/vidown/config";
  privateConfigPath = "${inputs.nix-secrets}/users/${username}/configs/vidown/config";
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

    # Prefer private per-user config from nix-secrets when present; keep the
    # public repo fallback non-private.
    xdg.configFile."vidown/config".source =
      config.lib.file.mkOutOfStoreSymlink configPath;
  };
}
