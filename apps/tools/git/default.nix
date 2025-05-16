{
  options,
  config,
  pkgs,
  lib,
  ...
}:
with lib;
with lib.custom; let
  cfg = config.apps.tools.git;
in {
  options.apps.tools.git = with types; {
    enable = mkBoolOpt true "Enable or disable git";
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      git
      git-remote-gcrypt
      gh
      lazygit
      commitizen
    ];

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

    home.configFile."git/config".text = import ./config.nix {sshKeyPath = "/home/${config.user.name}/.ssh/key.pub"; name = "alcxyz"; email = "me@alc.no";};
    home.configFile."lazygit/config.yml".source = ./lazygitConfig.yml;
  };
}
