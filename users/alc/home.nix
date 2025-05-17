{ config, pkgs, username, lib, ... }:

with lib;

{
  imports =
    [
      ./modules/home/environment.nix
      ./modules/home/desktop/default.nix # Imports general desktop options like colorscheme

      # Import the main Home Manager Hyprland desktop suite module
      ./modules/home/desktop/hyprland/default.nix

      # Import other Home Manager program modules (not part of the Hyprland suite)
      ./modules/home/programs/foot/default.nix
      ./modules/home/programs/wezterm/default.nix
      ./modules/home/programs/git/default.nix
      ./modules/home/programs/gnupg/default.nix
      ./modules/home/programs/ssh/default.nix
      ./modules/home/programs/rclone/default.nix
      # Removed individual Hyprland addon imports (swww) as they are now imported by ./modules/home/desktop/hyprland/default.nix
    ];
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = username;
  home.homeDirectory = "/home/${username}";
  xdg.cacheHome = "/home/${username}/.cache";
  xdg.configHome = "/home/${username}/.config";
  xdg.dataHome = "/home/${username}/.local/share";
  xdg.stateHome = "/home/${username}/.local/state";

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "24.11"; # Please read the comment before changing.

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = [
    # # Adds the 'hello' command to your environment. It prints a friendly
    # # "Hello, world!" when run.
    # pkgs.hello

    # # It is sometimes useful to fine-tune packages, for example, by applying
    # # overrides. You can do that directly here, just don't forget the
    # # parentheses. Maybe you want to install Nerd Fonts with a limited number of
    # # fonts?
    # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })

    # # You can also create simple shell scripts directly inside your
    # # configuration. For example, this adds a command 'my-hello' to your
    # # environment:
    # (pkgs.writeShellScriptBin "my-hello" ''
    #   echo "Hello, ${config.home.username}!"
    # '')
  ];

  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  home.file = {
    # # Building this configuration will create a copy of 'dotfiles/screenrc' in
    # # the Nix store. Activating the configuration will then make '~/.screenrc' a
    # # symlink to the Nix store copy.
    # ".screenrc".source = dotfiles/screenrc;

    # # You can also set the file content immediately.
    # ".gradle/gradle.properties".text = ''
    #   org.gradle.console=verbose
    #   org.gradle.daemon.idletimeout=3600000
    # '';
  };

  # Home Manager can also manage your environment variables through
  # 'home.sessionVariables'. These will be explicitly sourced when using a
  # shell provided by Home Manager. If you don't want to manage your shell
  # through Home Manager then you have to manually source 'hm-session-vars.sh'
  # located at either
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  ~/.local/state/nix/profiles/profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/root/etc/profile.d/hm-session-vars.sh
  #
  home.sessionVariables = {
    # EDITOR is now managed in modules/home/environment.nix
    # DIRENV_LOG_FORMAT is now managed in modules/home/environment.nix
  };

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # Enable and configure programs directly or via imported modules
  programs.foot.enable = true;
  programs.wezterm.enable = true;
  programs.git.enable = true;
  programs.gnupg.enable = true;
  programs.nix-ld.enable = true;
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Enable SSH client configuration via imported module
  programs.ssh.enable = true;

  # Enable Rclone via imported module (currently disabled in the module default)
  programs.rclone.enable = false;

  # Enable the Home Manager Hyprland desktop suite
  desktop.hyprland.enable = true;

  # Individual Hyprland addon enable options are now managed within the desktop.hyprland module.
  # Removed: desktop.hyprland.waybar.enable = true;
  # Removed: desktop.hyprland.swww.enable = true;

  # The desktop module (general options) is imported above, its options and configurations
  # are now available and merged into this configuration.
}
