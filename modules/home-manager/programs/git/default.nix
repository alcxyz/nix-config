{
  options,
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.programs.git.managed;

  defaultUserName = "alcxyz";
  defaultUserEmail = "me@alc.no";
  defaultSshKeyPath = "${config.home.homeDirectory}/.ssh/key.pub";

  defaultAliases = {
    gc = "commit -m";
    gca = "commit -a -m";
    gp = "push origin HEAD";
    gpu = "pull origin";
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
  };

  defaultExtraConfig = {
    pull.rebase = true;
    init.defaultBranch = "main";
    filter.lfs = {
      process = "git-lfs filter-process";
      required = true;
      clean = "git-lfs clean -- %f";
      smudge = "git-lfs smudge -- %f";
    };
    gpg.format = "ssh";
  };

in
{
  options.programs.git.managed = {
    enable = mkEnableOption "managed Git and Lazygit configuration";
    userName = mkOption {
      type = types.str;
      default = defaultUserName;
      description = "Git user name.";
    };
    userEmail = mkOption {
      type = types.str;
      default = defaultUserEmail;
      description = "Git user email.";
    };
    signingKey = mkOption {
      type = types.nullOr types.str;
      default = defaultSshKeyPath;
      description = "Path to GPG/SSH signing key for Git commits.";
    };
    signByDefault = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to sign commits by default.";
    };
    aliases = mkOption {
      type = types.attrsOf types.str;
      default = defaultAliases;
      description = "Git command aliases.";
    };
    extraConfig = mkOption {
      type = types.attrs;
      default = defaultExtraConfig;
      description = "Additional Git configurations.";
    };
    lazygit = {
      # Removed enable flag for lazygit here
      configFile = mkOption {
        type = types.nullOr types.path;
        default = ./lazygitConfig.yml; # Assumes co-located with this module file
        description = "Path to Lazygit's config.yml. Set to null to not manage this file.";
      };
    };
  };

  config = mkMerge [
    # Part 1: Git program configuration
    (mkIf cfg.enable {
      programs.git = {
        enable = true; # Enable the base home-manager git program
        userName = cfg.userName;
        userEmail = cfg.userEmail;
        signing = {
          key = cfg.signingKey;
          signByDefault = cfg.signByDefault;
        };
        extraConfig = cfg.extraConfig;
        aliases = cfg.aliases;
      };
    })

    # Part 2: Lazygit configuration file
    # This is now conditional on the main cfg.enable and if a configFile path is provided
    (mkIf (cfg.enable && cfg.lazygit.configFile != null) {
      home.configFile."lazygit/config.yml" = {
        source = cfg.lazygit.configFile;
      };
    })
  ];
}
