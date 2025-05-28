# users/alc/home-darwin.nix
{
  config,
  pkgs,
  lib,
  username,
  inputs,
  ...
}:

with lib;

{
  imports = [
    ./common.nix # <--- Import the common configuration first

    # macOS-specific imports (e.g., for yabai, skhd, system defaults)
    # Example: ../../modules/home-manager/macos/system-defaults.nix
    # Example: ../../modules/home-manager/programs/yabai/default.nix
    # Example: ../../modules/home-manager/programs/skhd/default.nix
  ];

  # ==================== macOS-Specific Options ====================
  # No need for home.username, home.homeDirectory, colorscheme, etc., as they are in common.nix

  home.packages = with pkgs; [
    # Packages specific to macOS (e.g., brave, iterm2, if not handled by an app manager)
    # brave
    # iterm2 # If available through nixpkgs, this would be the darwin version
    # visual-studio-code
  ];

  # Example macOS-specific program configurations
  # programs.yabai = { enable = true; ... };
  # services.skhd = { enable = true; ... };

  # Example: macOS desktop background or similar (different from Linux)
  # You might not use the same `wallpapers` directory for macOS,
  # or you'd use a different mechanism to set the background.
  # home.file.".config/something-macos".source = ./macos-specific-config-file;

  # Define macOS system settings or other defaults here, perhaps directly or via modules.
  # home.activation = {
  #   post = ''
  #     defaults write com.apple.finder CreateDesktop -bool false
  #     killall Finder
  #   '';
  # };
}
