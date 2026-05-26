{
  config,
  lib,
  pkgs,
  username,
  configDir,
  ...
}: let
  cfg = config.programs.videdupe;
  configPath = "${config.programs.workspace.root}/infra/nix-config/users/${username}/configs/videdupe/config";
in {
  options.programs.videdupe = {
    enable = lib.mkEnableOption "videdupe duplicate review TUI";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.videdupe;
      description = "Package providing the videdupe TUI.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [cfg.package];

    # Keep this mutable: editing the local nix-config checkout updates videdupe
    # defaults without needing a rebuild.
    xdg.configFile."videdupe/config".source =
      config.lib.file.mkOutOfStoreSymlink configPath;
  };
}
