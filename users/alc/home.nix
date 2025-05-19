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
    ../../modules/home-manager/services/hypridle/default.nix
    ../../modules/home-manager/services/hyprlock/default.nix

    # Other Home Manager program modules
    ../../modules/home-manager/programs/foot/default.nix
    ../../modules/home-manager/programs/wezterm/default.nix
    ../../modules/home-manager/programs/git/default.nix
    ../../modules/home-manager/programs/lazygit/default.nix
    #../../modules/home-manager/programs/gnupg/default.nix
    ../../modules/home-manager/programs/ssh/default.nix
    #../../modules/home-manager/programs/rclone/default.nix
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
  #xdg.cacheHome = "${config.home.homeDirectory}/.cache";
  #xdg.configHome = "${config.home.homeDirectory}/.config";
  #xdg.dataHome = "${config.home.homeDirectory}/.local/share";
  #xdg.stateHome = "${config.home.homeDirectory}/.local/state";

  home.sessionVariables = {
    EDITOR = "nvim";
    DIRENV_LOG_FORMAT = "";
    FLAKE = "/home/${username}/nix-config";
  };

  # ==================== Desktop Customization ====================
  # REMOVED: desktop.colorscheme = "catppuccin-mocha";

  # GTK theme settings
  # nix-colors will automatically configure
  # gtk.theme.name and gtk.theme.package based on config.colorscheme.name.
  gtk = {
    enable = true;
    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };
    # You can add other GTK settings here if needed, e.g.:
    # font.name = "Noto Sans 11";
  };

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
    ".face".source = ./profile.jpg;
    "Pictures/profile.jpg".source = ./profile.jpg;
    ".config/wallpapers" = {
      source = ./wallpapers;
      recursive = true;
    };
  };

  # ==================== Program and Feature Enabling ====================
  #DESKTOP AND WINDOW MANAGEMENT FOR LINUX ONLY
  programs.hyprland.managed.enable = false;
  programs.waybar.managed.enable = false;
  programs.wofi.managed.enable = false;
  programs.wlogout.managed.enable = false;
  services.swww.managed.enable = false;
  services.hypridle.managed.enable = false;
  services.hyprlock.enable = false;

  programs.foot.enable = true;
  programs.wezterm.enable = false;
  programs.git.managed.enable = true;
  programs.lazygit.managed.enable = true;
  #programs.gnupg.enable = true;
  programs.ssh.enable = true;

  /* programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  }; */

  #programs.rclone.enable = false;


    #LEAVE THIS COMMENT BLOCK FOR LATER - SIMPLY IGNORE IT FOR NOW!
    # Assuming prism is a Home Manager option (adjust if it's NixOS specific)
    # prism = {
    #   enable = true;
    #   wallpapers = ./wallpapers; # Path is now relative to this file (modules/home-manager/desktop/)
    #   colorscheme = inputs.nix-colors.colorschemes.${cfg.colorscheme};
    # };

}
