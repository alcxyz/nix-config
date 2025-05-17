# users/alc/home.nix
{
  config, # The Home Manager configuration being built
  pkgs,   # Package set (from homeManagerConfiguration's pkgs or extraSpecialArgs.pkgs)
  lib,    # Nixpkgs library functions
  username, # From extraSpecialArgs (value: "alc")
  inputs,   # From extraSpecialArgs (all flake inputs)
  pkgsFor,  # From extraSpecialArgs (the pkgsFor function)
  ...       # Catches any other arguments
}:

with lib; # Make lib functions available without `lib.` prefix

{
  # ==================== Imports ====================
  # These paths are relative to this home.nix file.
  # This is a common and clear way to structure Home Manager module imports.
  imports = [
    # General user environment settings
    ../../modules/home/environment.nix

    # Desktop environment general options (e.g., colorscheme)
    ../../modules/home/desktop/default.nix

    # Main Home Manager Hyprland desktop suite module
    ../../modules/home/desktop/hyprland/default.nix

    # User-specific shell configuration module
    ../../modules/home/shell/default.nix

    # Other Home Manager program modules
    ../../modules/home/programs/foot/default.nix
    ../../modules/home/programs/wezterm/default.nix
    ../../modules/home/programs/git/default.nix
    ../../modules/home/programs/gnupg/default.nix
    ../../modules/home/programs/ssh/default.nix
    ../../modules/home/programs/rclone/default.nix

    # You can also import modules from flake inputs if needed, e.g.:
    # inputs.nix-colors.homeManagerModules.nix-colors # Already added in flake.nix's homeConfigurations
  ];

  # ==================== Home Manager Core Settings ====================
  home.username = username; # Uses the 'username' argument passed from extraSpecialArgs
  home.homeDirectory = if pkgs.stdenv.isDarwin
                       then "/Users/${username}"
                       else "/home/${username}";
  home.stateVersion = "24.11";

  # Let Home Manager install and manage itself.
  # This is also set in your flake.nix's homeConfigurations for standalone,
  # but having it here is fine and makes this home.nix self-contained if used elsewhere.
  programs.home-manager.enable = true;

  # ==================== User Environment ====================
  # Configure user-specific environment variables and XDG paths.
  xdg.cacheHome = "${home.homeDirectory}/.cache";
  xdg.configHome = "${home.homeDirectory}/.config";
  xdg.dataHome = "${home.homeDirectory}/.local/share";
  xdg.stateHome = "${home.homeDirectory}/.local/state";

  # home.sessionVariables are typically set in modules/home/environment.nix
  # or directly here if they are very specific to this user profile.

  # ==================== Packages and Files ====================
  # User-specific packages managed by Home Manager.
  home.packages = with pkgs; [
    # Example: Add packages specific to 'alc' that aren't part of a module
    # neofetch
    # htop
  ];

  # Manage user dotfiles and directories.
  # Paths for 'source' are relative to this home.nix file.
  home.file = {
    "Documents/.keep".text = "";
    "Downloads/.keep".text = "";
    "Music/.keep".text = "";
    "Pictures/.keep".text = "";
    "dev/.keep".text = "";
    ".face".source = ./profile.png; # Assumes profile.png is next to home.nix
    "Pictures/profile.png".source = ./profile.png;
  };

  # ==================== Program and Feature Enabling ====================
  # Enable and configure programs and features, often defined in imported modules.
  # The options (e.g., desktop.hyprland.enable) should be defined in the
  # modules imported above.

  # === Desktop Environment and Related ===
  desktop.hyprland.enable = true; # Option from modules/home/desktop/hyprland/default.nix

  # === Shell and Terminal ===
  # Shell configuration is handled by modules/home/shell/default.nix
  # programs.nushell.enable would be set within that module.
  programs.foot.enable = true;    # Option from modules/home/programs/foot/default.nix
  programs.wezterm.enable = true; # Option from modules/home/programs/wezterm/default.nix

  # === Development and Version Control ===
  programs.git.enable = true; # Option from modules/home/programs/git/default.nix

  # === Security and Authentication ===
  programs.gnupg.enable = true; # Option from modules/home/programs/gnupg/default.nix
  programs.ssh.enable = true;   # Option from modules/home/programs/ssh/default.nix

  # === Utilities and Other Programs ===
  programs.nix-ld = {
    enable = true; # Standard Home Manager option
    package = pkgs.nix-ld; # Explicitly specify the package if needed
  };
  programs.direnv = {
    enable = true;          # Standard Home Manager option
    nix-direnv.enable = true; # Standard Home Manager option
  };

  programs.rclone.enable = false; # Option from modules/home/programs/rclone/default.nix

  # ==================== Nixpkgs Overlays/Configuration (Optional) ====================
  # If you need to apply overlays or specific configurations to the 'pkgs'
  # instance used by this Home Manager configuration:
  # nixpkgs.overlays = [
  #   (final: prev: {
  #     # myCustomPackage = prev.myCustomPackage.override { ... };
  #   })
  # ];
  # nixpkgs.config = {
  #   allowUnfree = true;
  #   # Other nixpkgs config options
  # };

  # ==================== Other Configurations ====================
  # Add any other top-level Home Manager options here.
  # For example, if you had a theming module:
  # theme.name = "catppuccin-mocha";
}
