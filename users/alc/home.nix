# users/alc/home.nix
{
  config, # The Home Manager configuration being built
  pkgs,   # Package set (from homeManagerConfiguration's pkgs or extraSpecialArgs.pkgs)
  lib,    # Nixpkgs library functions
  username, # From extraSpecialArgs (value: "alc")
  inputs,   # From extraSpecialArgs (all flake inputs)
  ...
}:

with lib;

# The 'let' block for gtkThemeFromScheme is likely no longer needed
# if it was only for the GTK theme package.
# If you use gtkThemeFromScheme for other purposes, you can keep it.
# let
#   inherit (inputs.nix-colors.lib-contrib {inherit pkgs;}) gtkThemeFromScheme;
# in
{
  # ==================== Imports ====================
  imports = [
    # User-specific shell configuration module
    ../../modules/home-manager/shell/default.nix

    # Moved Hyprland and related components
    ../../modules/home-manager/programs/hyprland/default.nix
    ../../modules/home-manager/programs/waybar/default.nix
    ../../modules/home-manager/programs/wofi/default.nix
    ../../modules/home-manager/programs/wlogout/default.nix
    ../../modules/home-manager/services/swww/default.nix
    ../../modules/home-manager/services/hypridle/default.nix # Your custom module
    ../../modules/home-manager/services/hyprlock/default.nix

    # Other Home Manager program modules
    ../../modules/home-manager/programs/foot/default.nix
    ../../modules/home-manager/programs/wezterm/default.nix
    ../../modules/home-manager/programs/git/default.nix
    #../../modules/home-manager/programs/gnupg/default.nix
    ../../modules/home-manager/programs/ssh/default.nix
    ../../modules/home-manager/programs/rclone/default.nix
  ];

  # ==================== Home Manager Core Settings ====================
  home.username = username;
  home.homeDirectory = if pkgs.stdenv.isDarwin
                       then "/Users/${username}"
                       else "/home/${username}";
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  # ==================== Nix-Colors Settings ====================
  # Use the standard nix-colors option to set the theme.
  # This will be available as config.colorscheme.*
  colorscheme.name = "catppuccin-mocha";

  # ==================== User Environment ====================
  xdg.cacheHome = "${home.homeDirectory}/.cache";
  xdg.configHome = "${home.homeDirectory}/.config";
  xdg.dataHome = "${home.homeDirectory}/.local/share";
  xdg.stateHome = "${home.homeDirectory}/.local/state";

  home.sessionVariables = {
    EDITOR = "nvim";
    DIRENV_LOG_FORMAT = "";
    FLAKE = "/home/${username}/nix-config";
  };

  # ==================== Desktop Customization ====================
  # REMOVED: desktop.colorscheme = "catppuccin-mocha";

  # GTK theme settings
  # Use the modern programs.gtk path. nix-colors will automatically configure
  # programs.gtk.theme.name and programs.gtk.theme.package based on config.colorscheme.name.
  programs.gtk = {
    enable = true;
    # The 'theme' sub-attribute for name and package is handled by nix-colors.
    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };
    # You can add other GTK settings here if needed, e.g.:
    # font.name = "Noto Sans 11";
  };
    
  # ... (rest of your configurations, packages, files, etc.)
  # Ensure the sections for home.packages, home.file, program enables are still here.

  # ==================== Packages and Files ====================
  home.packages = with pkgs; [
    # neofetch
    # htop
  ];

  home.file = {
    "Documents/.keep".text = "";
    "Downloads/.keep".text = "";
    "Music/.keep".text = "";
    "Pictures/.keep".text = "";
    "dev/.keep".text = "";
    ".face".source = ./profile.jpg;
    "Pictures/profile.jpg".source = ./profile.jpg;
    ".config/wallpapers" = {
      source = ./wallpapers;
      recursive = true;
    };
  };

  # ==================== Program and Feature Enabling ====================
  #DESKTOP AND WINDOW MANAGEMENT FOR LINUX ONLY
  programs.hyprland.enable = true;
  programs.waybar.enable = true;
  programs.wofi.enable = true;
  programs.wlogout.enable = true;
  services.swww.enable = true;
  services.hypridle.managed.enable = true; # Using your managed hypridle module
  services.hyprlock.enable = true;

  programs.foot.enable = true;
  programs.wezterm.enable = true;
  programs.git.managed.enable = true;
  #programs.gnupg.enable = true;
  programs.ssh.enable = true;

  programs.nix-ld = {
    enable = true;
    package = pkgs.nix-ld;
  };
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.rclone.enable = false;


    #LEAVE THIS COMMENT BLOCK FOR LATER - SIMPLY IGNORE IT FOR NOW!
    # Assuming prism is a Home Manager option (adjust if it's NixOS specific)
    # prism = {
    #   enable = true;
    #   wallpapers = ./wallpapers; # Path is now relative to this file (modules/home-manager/desktop/)
    #   colorscheme = inputs.nix-colors.colorschemes.${cfg.colorscheme};
    # };

}

