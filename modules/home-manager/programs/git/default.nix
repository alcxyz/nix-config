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
  # Path for the global default signing key
  defaultGlobalSigningKeyPath =
    "${config.home.homeDirectory}/.ssh/id_ed25519.pub";

  defaultAliases = { };

  defaultExtraConfig = {
    pull = { rebase = true; };                 # Corrected
    init = { defaultBranch = "main"; };        # Corrected
    filter.lfs = {                             # This was already correct
      process = "git-lfs filter-process";
      required = true;
      clean = "git-lfs clean -- %f";
      smudge = "git-lfs smudge -- %f";
    };
    gpg = { format = "ssh"; };                 # Corrected
  };

in
{
  options.programs.git.managed = {
    enable = mkEnableOption "managed Git configuration";

    userName = mkOption {
      type = types.str;
      default = defaultUserName;
      description = "Global default Git user name.";
    };

    userEmail = mkOption {
      type = types.str;
      default = defaultUserEmail;
      description = "Global default Git user email.";
    };

    # This is the GLOBAL DEFAULT signing key
    signingKey = mkOption {
      type = types.nullOr types.str;
      default = defaultGlobalSigningKeyPath;
      description =
        "Global default path to GPG/SSH signing key. Used if no conditional config matches or if a matching conditional config doesn't specify its own signing key.";
    };

    signByDefault = mkOption {
      type = types.bool;
      default = true;
      description =
        "Whether to sign commits by default globally. Conditional configs can override this by setting 'commit.gpgsign'.";
    };

    aliases = mkOption {
      type = types.attrsOf types.str;
      default = defaultAliases;
      description = "Git command aliases.";
    };

    extraConfig = mkOption {
      type = types.attrs; # types.attrsOf types.str would be more precise for git config
      default = defaultExtraConfig;
      description = "Additional global Git configurations.";
    };

    # New option for conditional configurations
    conditionalSigningConfigs = mkOption {
      type = types.attrsOf (types.attrsOf types.str); # Condition -> { git_config_key = git_config_value_as_string; ... }
      default = { };
      description = ''
        Attribute set for conditional Git configurations using 'includeIf'.
        The key of the outer attribute set is the condition string for 'includeIf.<condition>.path'
        (e.g., "gitdir:~/work/").
        The value is an attribute set of Git config key-value pairs (all values must be strings)
        to be applied under this condition. These will be written to separate include files.
        The paths in these configurations (like for 'user.signingkey') should be absolute
        or use tilde expansion (e.g., "~/.ssh/mykey.pub").
      '';
      example = {
        "gitdir:~/work/" = {
          "user.name" = "My Work Name";
          "user.email" = "my.work.email@example.com";
          "user.signingkey" = "~/.ssh/work_key.pub";
          "commit.gpgsign" = "true"; # Git expects string "true" or "false"
          "gpg.format" = "ssh"; # Can override global gpg.format if needed
        };
        "gitdir:~/personal/projectX/" = {
          "user.signingkey" = "~/.ssh/personal_key_for_X.pub";
          "user.email" = "me+projectX@alc.no";
          # Inherits global user.name unless specified here.
          # Inherits global commit.gpgsign (from signByDefault) unless 'commit.gpgsign' is set here.
        };
      };
    };
  };

  config = mkIf cfg.enable {
    # 1. Generate the include files for conditional configurations
    home.file = lib.mapAttrs' (condition: gitSettingsForCondition:
      let
        # Sanitize the condition string to create a safe filename
        # e.g., "gitdir:~/work/" becomes "gitdir---work-"
        sanitizedCondition = builtins.replaceStrings [ "/" ":" "~" "." ] [ "-" "-" "" "-" ] condition;
        filename = "git-conditional-${sanitizedCondition}.inc";
        # Target path for the include file within ~/.config/git/includes/
        # Git's includeIf.path can handle absolute paths.
        targetFilePath = "${config.xdg.configHome}/git/includes/${filename}";

        # Group settings by INI section (e.g., [user], [commit])
        # gitSettingsForCondition is { "user.signingkey" = "...", "commit.gpgsign" = "true", ... }
        # All values are already strings as per the option type.
        groupedSettings = lib.foldl' (acc: { name, value }:
          let
            parts = lib.splitString "." name;
            section = builtins.head parts;
            key = lib.concatStringsSep "." (builtins.tail parts);
          in if builtins.length parts > 1 && value != null then
               acc // { ${section} = (acc.${section} or { }) // { ${key} = value; }; }
             else acc
        ) { } (lib.mapAttrsToList (k: v: { name = k; value = v; }) gitSettingsForCondition);

        # Convert grouped settings to INI format string
        configFileContent = lib.concatStringsSep "\n" (
          lib.mapAttrsToList (sectionName: sectionAttrs:
            "[${sectionName}]\n" + (
              lib.concatStringsSep "\n" (
                lib.mapAttrsToList (keyName: keyValue: "  ${keyName} = ${keyValue}") sectionAttrs
              )
            )
          ) groupedSettings
        );
      in
      {
        # Name for the home.file entry (must be unique, use target path)
        name = targetFilePath;
        value = {
          text = configFileContent;
          # home.file will create parent directories for the target file if they don't exist.
        };
      }
    ) cfg.conditionalSigningConfigs;

    # 2. Configure programs.git with global settings and includeIf directives
    programs.git = {
      enable = true;
      aliases = cfg.aliases;

      userName = cfg.userName; # Global default user.name
      userEmail = cfg.userEmail; # Global default user.email
      signing = {
        key = cfg.signingKey; # Sets global default user.signingkey
        signByDefault = cfg.signByDefault; # Sets global default commit.gpgsign
      };

      # Combine user-provided global extraConfig with generated includeIf directives
      extraConfig = cfg.extraConfig // (
        lib.mapAttrs' (condition: settings:
          let
            sanitizedCondition = builtins.replaceStrings [ "/" ":" "~" "." ] [ "-" "-" "" "-" ] condition;
            filename = "git-conditional-${sanitizedCondition}.inc";
            # This path must match the one used in home.file above.
            # Git's includeIf.path resolves `~` so `~/.config/...` is also an option,
            # but absolute path from xdg.configHome is robust.
            includeFilePath = "${config.xdg.configHome}/git/includes/${filename}";
          in
          {
            name = "includeIf.${condition}.path";
            value = includeFilePath; # This will be an absolute path
          }
        ) cfg.conditionalSigningConfigs
      );
    };
  };
}
