{
  config,
  lib,
  pkgs,
  username,
  configDir,
  ...
}: let
  cfg = config.programs.vidown;
  configPath = "${config.programs.workspace.root}/infra/nix-secrets/users/${username}/configs/vidown/config";
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
