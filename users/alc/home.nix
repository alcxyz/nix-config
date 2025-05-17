{ config, pkgs, username, lib, ... }:

with lib;

{
  # ==================== Imports ====================
  imports =
    [
      # Import general user environment settings (e.g., PATH, other variables)
      ./modules/home/environment.nix

      # Import desktop environment general options (e.g., colorscheme)
      ./modules/home/desktop/default.nix

      # Import the main Home Manager Hyprland desktop suite module
      ./modules/home/desktop/hyprland/default.nix

      # Import the user-specific shell configuration module (Crucial addition)
      ./modules/home/shell/default.nix

      # Import other Home Manager program modules (not part of specific suites)
      # Note: foot, wezterm, git, gnupg, ssh, rclone are now enabled/configured below
      # via options provided by these imported modules.
      ./modules/home/programs/foot/default.nix
      ./modules/home/programs/wezterm/default.nix
      ./modules/home/programs/git/default.nix
      ./modules/home/programs/gnupg/default.nix
      ./modules/home/programs/ssh/default.nix
      ./modules/home/programs/rclone/default.nix
    ];

  # ==================== Home Manager Core Settings ====================
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = username;
  home.homeDirectory = "/home/${username}";

  # This value determines the Home Manager release that your configuration is
  # compatible with.
  home.stateVersion = "24.11"; # Please read the comment before changing.

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;


  # ==================== User Environment ====================
  # Configure user-specific environment variables and XDG paths.
  # Note: Some XDG variables might be set system-wide; Home Manager settings
  # often override or complement system settings in user sessions.
  xdg.cacheHome = "/home/${username}/.cache";
  xdg.configHome = "/home/${username}/.config";
  xdg.dataHome = "/home/${username}/.local/share";
  xdg.stateHome = "/home/${username}/.local/state";

  # home.sessionVariables = {
    # EDITOR and DIRENV_LOG_FORMAT are noted as being in modules/home/environment.nix
    # If other session variables are needed, add them here or in environment.nix.
  # };


  # ==================== Packages and Files ====================
  # User-specific packages managed by Home Manager.
  # Note: Some shell-related packages are installed via ./modules/home/shell/default.nix
  home.packages = [
    # Add other user-specific packages here
  ];

  # Manage user dotfiles and directories (integrated from old user module).
  home.file = {
    "Documents/.keep".text = "";
    "Downloads/.keep".text = "";
    "Music/.keep".text = "";
    "Pictures/.keep".text = "";
    "dev/.keep".text = "";
    ".face".source = ./profile.png; # Corrected path to ./profile.png
    "Pictures/profile.png".source = ./profile.png; # Corrected path to ./profile.png
  };


  # ==================== Program and Feature Enabling ====================
  # Enable and configure programs and features, often defined in imported modules.

  # === Desktop Environment and Related ===
  # Enable the Home Manager Hyprland desktop suite (imported above)
  desktop.hyprland.enable = true;

  # The general desktop module (general options like colorscheme) is imported above.

  # === Shell and Terminal ===
  # The shell configuration module is imported above and handles shell setup.
  # We can set options defined by the shell module here if needed.
  # programs.nushell.enable is set within ./modules/home/shell/default.nix

  programs.foot.enable = true;
  programs.wezterm.enable = true;

  # === Development and Version Control ===
  programs.git.enable = true;

  # === Security and Authentication ===
  programs.gnupg.enable = true; # Enabled here for logical grouping
  programs.ssh.enable = true; # Enabled here for logical grouping


  # === Utilities and Other Programs ===
  programs.nix-ld.enable = true; # Enables nix-ld for the user
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.rclone.enable = false;


  # ==================== Other Configurations ====================
  # Add any other top-level Home Manager options here.
}
