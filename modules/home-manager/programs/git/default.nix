# modules/home-manager/programs/git/default.nix
#
# Managed Git configuration module
# ---------------------------------
# This module builds a complete, reproducible Git configuration for the
# current user.  It provides:
#
#  * a single declarative place for global Git identity and defaults
#  * support for per‑directory conditional configurations using includeIf
#  * automatic generation of the small include files those conditions require
#
# All generated files live under XDG‑style paths, and the entire setup is
# transparent to Git: you can still override any value in a repo’s local config.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.git.managed;

  # --- default values that make sense for one user -----------------------

  defaultUserName  = "alcxyz";
  defaultUserEmail = "me@alc.no";

  # Global signing key (SSH public key used for commit signatures).
  # This path will be written literally into gitconfig.
  defaultSigningKey =
    "${config.home.homeDirectory}/.ssh/id_ed25519.pub";

  # Minimal but safe global alias set; empty by default.
  defaultAliases = { };

  # Reasonable global defaults:
  #   • rebase when pulling
  #   • default branch = main
  #   • enable Git‑LFS filter
  #   • sign with SSH format by default
  defaultSettings = {
    pull.rebase       = true;
    init.defaultBranch = "main";
    filter.lfs = {
      process  = "git-lfs filter-process";
      required = true;
      clean    = "git-lfs clean -- %f";
      smudge   = "git-lfs smudge -- %f";
    };
    gpg.format = "ssh";
  };
in
{
  # ----------------------------------------------------------------------
  # Option definitions
  # ----------------------------------------------------------------------

  options.programs.git.managed = {
    enable = mkEnableOption "Declarative global Git configuration";

    userName = mkOption {
      type = types.str;
      default = defaultUserName;
      description = "Globally used Git user name.";
    };

    userEmail = mkOption {
      type = types.str;
      default = defaultUserEmail;
      description = "Globally used Git e‑mail address.";
    };

    signingKey = mkOption {
      type = types.nullOr types.str;
      default = defaultSigningKey;
      description = ''
        Path to the default SSH or GPG signing key.
        Used when no conditional rule provides its own key.
      '';
    };

    signByDefault = mkOption {
      type = types.bool;
      default = true;
      description = "Sign commits by default (sets commit.gpgsign).";
    };

    aliases = mkOption {
      type = types.attrsOf types.str;
      default = defaultAliases;
      description = "Global Git command aliases (equivalent to [alias] section).";
    };

    extraConfig = mkOption {
      type = types.attrs;
      default = defaultSettings;
      description = "Additional global Git configuration entries.";
    };

    # Map of includeIf conditions → sub‑configs.
    # Each value is itself an attribute set of plain Git settings.
    conditionalSigningConfigs = mkOption {
      type = types.attrsOf (types.attrsOf types.str);
      default = { };
      description = ''
        Conditional configurations using Git’s `includeIf` feature.
        Example:

        {
          "gitdir:~/work/" = {
            "user.name" = "Work ID";
            "user.email" = "id@company.com";
            "user.signingkey" = "~/.ssh/work_key.pub";
            "commit.gpgsign" = "true";
          };
        }
      '';
    };
  };

  # ----------------------------------------------------------------------
  # Actual configuration
  # ----------------------------------------------------------------------

  config = mkIf cfg.enable {

    # --- Generate include files for each conditional block ---------------
    #
    # Git’s includeIf mechanism points to separate files; we materialize
    # those files here at evaluation time so they are always in sync with
    # the declarations above.

    home.file =
      lib.mapAttrs'
        (condition: gitSettings:
          let
            # Transform a condition such as “gitdir:~/work/” into a safe
            # file name “gitdir---work-”.
            sanitized   =
              builtins.replaceStrings [ "/" ":" "~" "." ] [ "-" "-" "" "-" ] condition;
            filename    = "git-conditional-${sanitized}.inc";
            targetPath  = "${config.xdg.configHome}/git/includes/${filename}";

            # Group dotted keys like "user.signingkey" into INI sections.
            grouped =
              lib.foldl'
                (acc: { name, value }:
                  let
                    parts   = lib.splitString "." name;
                    section = builtins.head parts;
                    key     = builtins.concatStringsSep "." (builtins.tail parts);
                  in acc // { ${section} =
                       (acc.${section} or { }) // { ${key} = value; }; })
                { }
                (lib.mapAttrsToList (k: v: { name = k; value = v; }) gitSettings);

            # Render the section map into a minimal INI text file.
            iniText =
              lib.concatStringsSep "\n"
                (lib.mapAttrsToList
                  (section: kvs:
                    "[${section}]\n"
                      + (lib.concatStringsSep "\n"
                          (lib.mapAttrsToList (k: v: "  ${k} = ${v}") kvs)))
                  grouped);
          in {
            name  = targetPath;
            value = { text = iniText; };
          })
        cfg.conditionalSigningConfigs;

    # --- Build the global Git configuration itself ----------------------

    programs.git = {
      enable = true;

      # All current Git settings go under `settings`, which directly maps
      # to git‑config keys and sections.
      settings =
        cfg.extraConfig
        // {
          # Identity and signing defaults.
          user.name       = cfg.userName;
          user.email      = cfg.userEmail;
          user.signingkey = cfg.signingKey;
          commit.gpgsign  = cfg.signByDefault;
          alias           = cfg.aliases;
        }
        # Add includeIf rules that reference the files we generated above.
        // lib.mapAttrs'
          (condition: _:
            let
              sanitized  =
                builtins.replaceStrings [ "/" ":" "~" "." ] [ "-" "-" "" "-" ] condition;
              filename   = "git-conditional-${sanitized}.inc";
              includePath =
                "${config.xdg.configHome}/git/includes/${filename}";
            in {
              name  = "includeIf.${condition}.path";
              value = includePath;
            })
          cfg.conditionalSigningConfigs;
    };
  };
}
