{
  options,
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  # cfg will now refer to our managed options
  cfg = config.programs.git.managed;

  # Default values for some managed options
  defaultUserName = "alcxyz";
  defaultUserEmail = "me@alc.no";
  defaultSshKeyPath = "${config.home.homeDirectory}/.ssh/key.pub"; # Use actual home dir

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
      type = types.nullOr types.str; # Allow null if not signing
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
      type = types.attrs; # More flexible for nested structures
      default = defaultExtraConfig;
      description = "Additional Git configurations.";
    };

    lazygit = {
      enable = mkEnableOption "Lazygit configuration";
      configFile = mkOption {
        type = types.nullOr types.path;
        default = ./lazygitConfig.yml; # Assumes it's co-located
        description = "Path to Lazygit's config.yml. Set to null to disable.";
      };
    };
  };

  config = mkIf cfg.enable { # This is the main switch for this managed module
    programs.git = {
      enable = true; # Enable the standard Home Manager git module
      userName = cfg.userName;
      userEmail = cfg.userEmail;
      signing = {
        key = cfg.signingKey;
        signByDefault = cfg.signByDefault;
      };
      extraConfig = cfg.extraConfig;
      aliases = cfg.aliases;
    };

    # Configure lazygit if its specific enable flag is true and configFile is set
    home.configFile."lazygit/config.yml" = mkIf (cfg.lazygit.enable && cfg.lazygit.configFile != null) {
      source = cfg.lazygit.configFile;
    };
  };
}
