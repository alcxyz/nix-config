{
  options,
  config,
  pkgs,
  lib,
  ...
}:
with lib;
# Removed 'with lib.custom;'
let
  cfg = config.system.fonts;
in {
  options.system.fonts = with lib.types; { # Explicitly use lib.types
    enable = lib.mkEnableOption "Whether or not to manage fonts.";
    fonts = lib.mkOption {
      type = listOf package; # 'listOf' and 'package' are from lib.types
      default = [];
      description = "Custom font packages to install.";
    };
  };

  config = mkIf cfg.enable {
    environment.variables = {
      # Enable icons in tooling since we have nerdfonts.
      LOG_ICONS = "true";
    };

    environment.systemPackages = with pkgs; [font-manager];

    fonts.packages = with pkgs;
      [
        noto-fonts
        noto-fonts-cjk-sans
        noto-fonts-cjk-serif
        noto-fonts-emoji
        #(nerdfonts.override {fonts = ["JetBrainsMono"];})
        nerd-fonts.jetbrains-mono
      ]
      ++ cfg.fonts; # cfg.fonts refers to options.system.fonts.fonts
  };
}
