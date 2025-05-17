{
  options,
  config,
  pkgs,
  lib,
  ...
}:
with lib;

let
  cfg = config.programs.git; # Updated option path
in
{
  options.programs.git = with types; { # Updated option path
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable git Home Manager configuration (aliases and config files)."; # Updated description
    };
  };

  config = mkIf cfg.enable {
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