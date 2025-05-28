# modules/home-manager/programs/git/default.nix
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
    enable = mkEnableOption "managed Git configuration";

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
  };

  config = mkIf cfg.enable {
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
    # Removed lazygit package and configFile from here
  };
}

