# users/alc/common.nix
{
  config,
  pkgs,
  lib,
  username,
  hostName,
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
    ../../modules/home-manager/programs/ssh/default.nix
    ../../modules/home-manager/secrets/ssh-keys.nix
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

  # Swtich aliases
  home.shellAliases = {
    hmsw = "home-manager switch --flake .#alc-${hostName}";
  };

  # ==================== Packages ====================
  home.packages = with pkgs; [
    # Packages that are available and desired on both OSes
    tree
    neofetch
    htop
    btop
    bat
    gitui
    xh
    dua
    yazi
    ripgrep-all
    wiki-tui
    gopass
    yubico-piv-tool
    age
    age-plugin-yubikey
    yq
    youtube-music
    azure-cli
    google-cloud-sdk
    devbox
    atac
    termshark
    openldap
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
  programs.ssh.enable = true;

  programs.ncspot.enable = true;

}
