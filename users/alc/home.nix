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

let # ADDED LET BLOCK
  # Make gtkThemeFromScheme available
  inherit (inputs.nix-colors.lib-contrib {inherit pkgs;}) gtkThemeFromScheme;
in
{
  # ==================== Imports ====================
  imports = [
    # General user environment settings
    ../../modules/home-manager/environment.nix

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
    ../../modules/home-manager/programs/gnupg/default.nix
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

  # ==================== User Environment ====================
  xdg.cacheHome = "${home.homeDirectory}/.cache";
  xdg.configHome = "${home.homeDirectory}/.config";
  xdg.dataHome = "${home.homeDirectory}/.local/share";
  xdg.stateHome = "${home.homeDirectory}/.local/state";

  # ==================== Desktop Customization (Moved from desktop/default.nix) ====================
  # Define the colorscheme directly
  desktop.colorscheme = "catppuccin-mocha";

  # GTK theme settings (previously in desktop/default.nix)
  home.extraOptions.gtk = {
    enable = true;
    theme = {
      name = inputs.nix-colors.colorschemes.${config.desktop.colorscheme}.slug;
      package = gtkThemeFromScheme {scheme = inputs.nix-colors.colorschemes.${config.desktop.colorscheme};};
    };
    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };
  };

    # Assuming prism is a Home Manager option (adjust if it's NixOS specific)
    # prism = {
    #   enable = true;
    #   wallpapers = ./wallpapers; # Path is now relative to this file (modules/home-manager/desktop/)
    #   colorscheme = inputs.nix-colors.colorschemes.${cfg.colorscheme};
    # };

    # GTK theme setting - note that gtkThemeFromScheme is used below for a HM-managed theme
    # This environment variable might be redundant or conflict depending on setup.
    # Consider removing this if home.extraOptions.gtk handles it fully.
    # environment.variables = {
    #   GTK_THEME = "Catppuccin-Mocha-Compact-Blue-dark"; # Original value, consider deriving from colorscheme
    # };

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
    ".face".source = ./profile.png;
    "Pictures/profile.png".source = ./profile.png;
    ".config/wallpapers" = {
      source = ./wallpapers;
      recursive = true;
    };
  };

  # ==================== Program and Feature Enabling ====================
  programs.hyprland.enable = true;
  programs.waybar.enable = true;
  programs.wofi.enable = true;
  programs.wlogout.enable = true;
  services.swww.enable = true;
  services.hypridle.enable = true;
  services.hyprlock.enable = true;

  programs.foot.enable = true;
  programs.wezterm.enable = true;
  programs.git.enable = true;
  programs.gnupg.enable = true;
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

  # ==================== Nixpkgs Overlays/Configuration (Optional) ====================
  # nixpkgs.overlays = [
  #   (final: prev: {
  #     # myCustomPackage = prev.myCustomPackage.override { ... };
  #   })
  # ];
  # nixpkgs.config = {
  #   allowUnfree = true;
  # };

  # ==================== Other Configurations ====================
  # theme.name = "catppuccin-mocha";
}
