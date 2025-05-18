{
  config,
  pkgs,
  lib,
  ...
}:
with lib;

let
  # Define user details here for clarity or fetch from a central place if available
  userName = "alcxyz"; # As per your original config.nix import
  userEmail = "me@alc.no"; # As per your original config.nix import
  sshKeyPath = "/home/${config.home.username}/.ssh/key.pub"; # Dynamically get user's home
in
{
  # This module configures the built-in Home Manager programs.git module.
  # It does not define its own enable option, but depends on programs.git.enable being set elsewhere.

  config = mkIf config.programs.git.enable {
    programs.git = {
      enable = true; # Ensure git itself is enabled if not done elsewhere
      userName = userName;
      userEmail = userEmail;
      signing = {
        key = sshKeyPath;
        signByDefault = true;
      };
      extraConfig = {
        pull.rebase = true;
        init.defaultBranch = "main";
        filter.lfs = {
          process = "git-lfs filter-process";
          required = true;
          clean = "git-lfs clean -- %f";
          smudge = "git-lfs smudge -- %f";
        };
        gpg.format = "ssh"; # For signing commits with SSH keys
      };
      aliases = {
        gc = "commit -m";
        gca = "commit -a -m";
        gp = "push origin HEAD";
        gpu = "pull origin"; # Consider 'pull --rebase' if that's your workflow
        gst = "status";
        glog = "log --graph --topo-order --pretty='%w(100,0,6)%C(yellow)%h%C(bold)%C(black)%d %C(cyan)%ar %C(green)%an%n%C(bold)%C(white)%s %N' --abbrev-commit";
        gdiff = "diff";
        gco = "checkout";
        gb = "branch";
        gba = "branch -a";
        gadd = "add";
        ga = "add -p";
        gcoall = "checkout -- .";
        gr = "remote";
        gre = "reset";
        g = "lazygit"; # This is an alias to a program, not a git subcommand
      };
    };

    # Configure lazygit config file
    # The source path is relative to this default.nix file's location if it's in the same directory.
    # If lazygitConfig.yml is in the same directory as this default.nix:
    home.configFile."lazygit/config.yml".source = ./lazygitConfig.yml;
    # If it's in a different location, adjust the path like below:
    # home.configFile."lazygit/config.yml".source = ../../path/to/lazygitConfig.yml;

    # Note: The alias `g = "lazygit"` is kept. If `lazygit` is available in PATH,
    # this alias will work. Otherwise, you might need to ensure lazygit is in home.packages.
    # Since it's an alias for a program, not a git subcommand, it is correctly placed in programs.git.aliases
    # which are aliases for the `git` command itself. If you want `g` as a general shell alias,
    # it should be in `home.shellAliases` in your shell module.
    # For now, keeping it as a git alias `git g` which expands to `git lazygit` (which is likely not what you want).
    # Moving g = "lazygit" to shellAliases for direct use.
  };

  # Moving g = "lazygit" to general shell aliases for direct use,
  # as it's a command, not a git subcommand.
  # This assumes you want to type 'g' to run 'lazygit'.
  # If you have a global shell alias file, it's better to put it there.
  # For now, adding it to home.shellAliases if that's managed by home-manager.
  # This requires knowing if home.shellAliases is available and how it's structured.
  # Based on your shell/default.nix, it is `home.shellAliases`.

  # The following line assumes that this git module can append to home.shellAliases.
  # This might not be ideal if modules are meant to be perfectly isolated.
  # A better approach is to define this alias in your main shell configuration module.
  # However, to consolidate git-related things, one might argue to keep it here.
  # Given the user's request to "consolidate", we'll try to keep it related.
  # The original `g = "lazygit"` was in `environment.shellAliases` within the old git module.
  # The most direct Home Manager equivalent for general aliases is `home.shellAliases`.

  # Let's ensure `lazygit` is directly callable if `g = "lazygit"` is intended as a shell alias.
  # The error message implies a module structure issue, not an alias issue directly.
  # The `programs.git.aliases` are for `git <alias>` commands.
  # `g = "lazygit"` is NOT a `git` subcommand alias.
  # It should be in `home.shellAliases` in your `modules/home-manager/shell/default.nix`.

  # Correctly, git specific aliases are in `programs.git.aliases`.
  # The alias `g = "lazygit"` should be moved to your `modules/home-manager/shell/default.nix`
  # if you want to type `g` and run `lazygit`.
  # I will remove it from here to avoid confusion, as this file is for `programs.git` settings.
}
