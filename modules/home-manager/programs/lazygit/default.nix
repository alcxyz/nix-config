# modules/home-manager/programs/lazygit/default.nix
{
  options,
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.programs.lazygit.managed;
in
{
  options.programs.lazygit.managed = {
    enable = mkEnableOption "managed Lazygit configuration";
    # You could add more lazygit specific options here if needed in the future
    # For now, we'll assume a static config file.
  };

  config = mkIf cfg.enable {
    home.packages = [ pkgs.lazygit ];

    home.configFile."lazygit/config.yml" = {
      # Assumes lazygitConfig.yml is co-located with this module file
      # Create this file: modules/home-manager/programs/lazygit/lazygitConfig.yml
      source = ./lazygitConfig.yml;
    };
  };
}

