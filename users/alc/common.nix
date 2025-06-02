# users/alc/common.nix
{
  config,
  pkgs,
  lib,
  username,
  inputs,
  system,
  ...
}:

with lib;

{
  # ==================== Imports of truly common modules ====================
  imports = [
    # These are modules that are guaranteed to work on both OSes
    # or handle their own platform differences internally if needed
    ../../modules/home-manager/shell/default.nix
    ../../modules/home-manager/programs/wezterm/default.nix
    ../../modules/home-manager/programs/git/default.nix
    ../../modules/home-manager/programs/lazygit/default.nix
    # Consider if gnupg and ssh need platform-specific tweaks, but often they are largely common
    ../../modules/home-manager/programs/gpg/default.nix
    ../../modules/home-manager/programs/ssh/default.nix
    #../../modules/home-manager/programs/rclone/default.nix

    # Direnv is a great example of a common program
    # You could put its configuration directly here, or if it has its own module:
    # ../../modules/home-manager/programs/direnv/default.nix (if you create one)
  ];

  # ==================== Home Manager Core Settings ====================
  home.username = username;
  # This still needs a conditional, as `homeDirectory` is fundamentally different!
  home.homeDirectory = if pkgs.stdenv.isDarwin
                       then "/Users/${username}"
                       else "/home/${username}";
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  # ==================== Nix-Colors Settings ====================
  colorscheme.name = "catppuccin-mocha";

  # ==================== User Environment ====================
  home.sessionVariables = {
    EDITOR = "nvim";
    DIRENV_LOG_FORMAT = "";
    # FLAKE path still needs to be conditional, as it's an absolute path
    # relative to the OS's file system root
    FLAKE = if pkgs.stdenv.isDarwin
            then "/Users/${username}/nix-config"
            else "/home/${username}/nix-config";
  };

  # ==================== Packages ====================
  home.packages = with pkgs; [
    # Packages that are available and desired on both OSes
    neofetch
    htop
    ncspot
  ];

  # ==================== Files ====================
  home.file = {
    "Documents/.keep".text = "";
    "Downloads/.keep".text = "";
    "Music/.keep".text = "";
    "Pictures/.keep".text = "";
    # Profile picture is usually common regardless of OS
    ".face".source = ./profile.jpg; # Relative to users/alc/
    "Pictures/profile.jpg".source = ./profile.jpg;

    # If you have general dotfiles that are always the same
    # e.g., a common nvim config
    # ".config/nvim/init.lua".source = ../../path/to/common/nvim/init.lua;
  };

  # ==================== Program Enabling for Common Programs ====================
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.wezterm.enable = true;
  programs.git.managed.enable = true;
  programs.lazygit.managed.enable = true;
  programs.ssh.enable = true;

  programs.gpg.managed = {
    enable = true;
    #defaultKey = "YOUR_GPG_KEY_ID_HERE"; # Optional: your GPG key ID

    agent = {
      enableSshSupport = true;

      # --- For macOS ---
      #pinentryPackage = pkgs.pinentry_mac;

      # --- For Linux (example with Qt pinentry) ---
      # pinentryPackage = pkgs.pinentry-qt;
      # --- Or for GTK ---
      # pinentryPackage = pkgs.pinentry-gtk2;
      # --- Or for curses (terminal) ---
      # pinentryPackage = pkgs.pinentry-curses;

      defaultCacheTtl = 3600; # 1 hour
      maxCacheTtl = 7200;   # 2 hours
      # extraConfig = ''
      #   debug-level guru
      # '';
    };
  };
}
