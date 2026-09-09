# nix-config/modules/nixos/services/forge-mirror-audit/default.nix
#
# Periodically audits Forgejo-first repos against GitHub mirrors.
{
  config,
  pkgs,
  inputs,
  lib,
  ...
}: let
  cfg = config.services.forge-mirror-audit;
  repositoryPolicyFile = name: repositories: pkgs.writeText name (lib.concatStringsSep "\n" repositories);
  requiredScalar = name: value:
    if value == null || value == ""
    then throw "services.forge-mirror-audit.${name} must be set to a non-empty value."
    else value;
  requiredRepositories = name: repositories:
    if repositories == null
    then throw "services.forge-mirror-audit.${name} must be explicitly set from repository policy."
    else repositories;
  forgejoUrl = requiredScalar "forgejoUrl" cfg.forgejoUrl;
  forgejoUser = requiredScalar "forgejoUser" cfg.forgejoUser;
  githubUser = requiredScalar "githubUser" cfg.githubUser;
  githubPrimaryRepositoriesFile =
    repositoryPolicyFile "forge-mirror-github-primary-repos"
    (requiredRepositories "githubPrimaryRepositories" cfg.githubPrimaryRepositories);
  githubDeniedRepositoriesFile =
    repositoryPolicyFile "forge-mirror-github-denied-repos"
    (requiredRepositories "githubDeniedRepositories" cfg.githubDeniedRepositories);
  requiredPrivateRepositoriesFile =
    repositoryPolicyFile "forge-mirror-required-private-repos"
    (requiredRepositories "requiredPrivateRepositories" cfg.requiredPrivateRepositories);
in {
  options.services.forge-mirror-audit = {
    enable = lib.mkEnableOption "forge-mirror Forgejo/GitHub drift audit";

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 00/8:00:00";
      description = "Systemd timer schedule (OnCalendar value). Default: every 8 hours.";
      example = "daily";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "User to run the service as.";
    };

    forgejoUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Base URL for the Forgejo API. Required when the service is enabled.";
    };

    forgejoUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Forgejo account whose repositories are audited. Required when the service is enabled.";
    };

    githubUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "GitHub account whose mirrors are audited. Required when the service is enabled.";
    };

    githubPrimaryRepositories = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = ''
        Repository names excluded from Forgejo-primary mirroring and drift
        checks. Supply the same repository policy inventory used by interactive
        forge-mirror commands. Required when the service is enabled. An
        explicit empty list is valid when no repositories are excluded.
      '';
      example = [
        "public-app"
        "upstream-fork"
      ];
    };

    githubDeniedRepositories = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = ''
        Repository names that policy prohibits publishing to GitHub. Required
        when the service is enabled. An explicit empty list is valid when no
        repositories are denied.
      '';
      example = ["internal-tool"];
    };

    requiredPrivateRepositories = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = ''
        Repository names whose Forgejo visibility must remain private.
        Required when the service is enabled. An explicit empty list is valid
        when no repositories require it.
      '';
      example = ["private-service"];
    };

    credentials = {
      sopsFile = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.oneOf [
            lib.types.path
            lib.types.str
          ]
        );
        default = null;
        description = "Private sops file containing forge mirror credentials.";
      };

      forgejoKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Sops key for the Forgejo token.";
      };

      githubKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Sops key for the GitHub token.";
      };

      codebergKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Deprecated compatibility option; the audit does not consume a Codeberg token.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.credentials.sopsFile != null;
        message = "services.forge-mirror-audit.credentials.sopsFile must be set privately.";
      }
      {
        assertion = cfg.credentials.forgejoKey != null;
        message = "services.forge-mirror-audit.credentials.forgejoKey must be set privately.";
      }
      {
        assertion = cfg.credentials.githubKey != null;
        message = "services.forge-mirror-audit.credentials.githubKey must be set privately.";
      }
    ];

    sops.secrets.forge_mirror_forgejo_token = {
      sopsFile = cfg.credentials.sopsFile;
      key = cfg.credentials.forgejoKey;
      owner = cfg.user;
      mode = "0400";
    };

    sops.secrets.forge_mirror_github_token = {
      sopsFile = cfg.credentials.sopsFile;
      key = cfg.credentials.githubKey;
      owner = cfg.user;
      mode = "0400";
    };

    systemd.services.forge-mirror-audit = {
      description = "Audit Forgejo-first drift against GitHub mirrors";
      after = ["network-online.target"];
      wants = ["network-online.target"];

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = "root";

        ExecStart = pkgs.writeShellScript "forge-mirror-audit-wrapper" ''
          set -euo pipefail
          export PATH="${
            lib.makeBinPath [
              pkgs.git
              pkgs.coreutils
            ]
          }:$PATH"
          export FORGEJO_TOKEN_FILE="${config.sops.secrets.forge_mirror_forgejo_token.path}"
          export GITHUB_MIRROR_PAT_FILE="${config.sops.secrets.forge_mirror_github_token.path}"
          export FORGEJO_URL=${lib.escapeShellArg forgejoUrl}
          export FORGEJO_USER=${lib.escapeShellArg forgejoUser}
          export GITHUB_USER=${lib.escapeShellArg githubUser}
          export FORGE_MIRROR_GITHUB_PRIMARY_REPOS_FILE=${githubPrimaryRepositoriesFile}
          export FORGE_MIRROR_GITHUB_DENIED_REPOS_FILE=${githubDeniedRepositoriesFile}
          export FORGE_MIRROR_REQUIRED_PRIVATE_REPOS_FILE=${requiredPrivateRepositoriesFile}
          exec ${pkgs.forge-mirror}/bin/forge-mirror audit
        '';

        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "forge-mirror-audit";
      };
    };

    systemd.timers.forge-mirror-audit = {
      description = "Timer for forge-mirror drift audit";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        Unit = "forge-mirror-audit.service";
      };
    };
  };
}
