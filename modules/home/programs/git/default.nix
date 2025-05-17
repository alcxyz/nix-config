{
  config,
  pkgs,
  lib,
  ...
}:
with lib;

{
  # This module configures the built-in Home Manager programs.git module.
  # It does not define its own enable option, but depends on programs.git.enable being set elsewhere.

  config = mkIf config.programs.git.enable { # Use the built-in enable option
    # Home Manager configurations for Git
    environment.shellAliases = {
      # Git
      gc = "git commit -m";
      gca = "git commit -a -m";
      gp = "git push origin HEAD";
      gpu = "git pull origin";
      gst = "git status";
      glog = "git log --graph --topo-order --pretty='%w(100,0,6)%C(yellow)%h%C(bold)%C(black)%d %C(cyan)%ar %C(green)%an%n%C(bold)%C(white)%s %N' --abbrev-commit";
      gdiff = "git diff";
      gco = "git checkout";
      gb = "git branch";
      gba = "git branch -a";
      gadd = "git add";
      ga = "git add -p";
      gcoall = "git checkout -- .";
      gr = "git remote";
      gre = "git reset";

      g = "lazygit";
    };

    # Configure git config and lazygit config files
    home.configFile."git/config".text = import ./config.nix {sshKeyPath = "/home/${config.user.name}/.ssh/key.pub"; name = "alcxyz"; email = "me@alc.no";}; # Path relative to this module
    home.configFile."lazygit/config.yml".source = ./lazygitConfig.yml; # Path relative to this module
  };
}