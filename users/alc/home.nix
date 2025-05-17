{ config, pkgs, username, lib, ... }:

with lib;

{
  imports =
    [
      ./modules/home/environment.nix
      ./modules/home/desktop/default.nix # Import the new desktop module
      ./modules/home/programs/foot/default.nix # Import the foot module from its new directory
      ./modules/home/programs/wezterm/default.nix # Import the new WezTerm module
      # Removed ./modules/home/programs/direnv/default.nix
      ./modules/home/programs/git/default.nix # Import the new Git module
      ./modules/home/programs/gnupg/default.nix # Import the new GnuPG module
      ./modules/home/programs/ssh/default.nix # Import the new SSH client module
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

  # Enable and configure programs directly
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

  # The desktop module is imported above, its options and configurations
  # are now available and merged into this configuration.
}
