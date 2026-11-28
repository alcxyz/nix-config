# nix-config/modules/nixos/services/forge-mirror-audit/default.nix
#
# Periodically audits Forgejo-first repos against GitHub mirrors. With
# alert.enable, each run reports to its own Healthchecks check instead of
# failing the nixfleet boot check, so policy findings no longer surface as a
# storage alert.
{
  config,
  pkgs,
  inputs,
  lib,
  ...
}: let
  cfg = config.services.forge-mirror-audit;
  alert = cfg.alert;
  storage = config.services.storage-health-monitor;
  unitName = "forge-mirror-audit.service";
  runtimeDirectory = "/run/forge-mirror-audit";
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

    alert = {
      enable = lib.mkEnableOption ''
        reporting each audit run to its own Healthchecks check: start, success
        on a clean audit and fail with the summary line otherwise. The audit
        unit then no longer fails the nixfleet boot check'';
      pingBaseFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default =
          if storage.enable
          then storage.pingBaseFile
          else null;
        defaultText = lib.literalExpression "config.services.storage-health-monitor.pingBaseFile when that monitor is enabled, else null";
        description = ''
          Runtime file containing the private Healthchecks project ping base.
          It is read at runtime and never placed on a command line.
        '';
      };
      slug = lib.mkOption {
        type = lib.types.strMatching "[a-z0-9-]+";
        default = "forge-mirror-audit-${lib.toLower config.networking.hostName}";
        defaultText = lib.literalExpression ''"forge-mirror-audit-''${lib.toLower config.networking.hostName}"'';
        description = ''
          Healthchecks check slug, created on first ping. Per host by default,
          since hosts share the project ping base and must not share a check.
        '';
      };
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

      forgejoSopsFile = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.oneOf [
            lib.types.path
            lib.types.str
          ]
        );
        default = null;
        description = "Optional private sops file for the Forgejo token; defaults to credentials.sopsFile.";
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
      {
        assertion = !alert.enable || alert.pingBaseFile != null;
        message = "services.forge-mirror-audit.alert needs a project pingBaseFile, supplied explicitly or by storage-health-monitor.pingBaseFile.";
      }
    ];

    # Findings are reported to the audit's own check; a failed audit unit is
    # no failed boot.
    services.nixfleet-boot-check.ignoredFailedUnits = lib.mkIf alert.enable [unitName];

    sops.secrets.forge_mirror_forgejo_token = {
      sopsFile =
        if cfg.credentials.forgejoSopsFile != null
        then cfg.credentials.forgejoSopsFile
        else cfg.credentials.sopsFile;
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

      serviceConfig =
        {
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
            ${
              if alert.enable
              then ''
                export PATH="${
                  lib.makeBinPath [
                    pkgs.curl
                    pkgs.gnugrep
                    pkgs.python3
                  ]
                }:$PATH"
                report=${runtimeDirectory}/report
                output=${runtimeDirectory}/output
                : >"$report"
                : >"$output"

                # The ping base stays in its file; send-ping.py hands it to curl
                # on standard input. A failed ping never changes the audit result.
                send_ping() {
                  timeout --signal=KILL 10s python3 ${../storage-health-monitor/send-ping.py} \
                    base ${lib.escapeShellArg alert.pingBaseFile} ${lib.escapeShellArg alert.slug} \
                    "$1" "$report" ||
                    echo "forge-mirror-audit: healthcheck ping failed" >&2
                }

                send_ping /start
                status=0
                ${pkgs.forge-mirror}/bin/forge-mirror audit | tee "$output" || status=''${PIPESTATUS[0]}
                if [ "$status" -eq 0 ]; then
                  send_ping ""
                else
                  # Only the summary line, which holds counts and no names or
                  # credentials, goes into the report.
                  {
                    grep '^audit: ' "$output" || echo "audit: no summary line"
                    echo "forge-mirror audit exited $status"
                  } >"$report"
                  send_ping /fail
                fi
                exit "$status"
              ''
              else ''
                exec ${pkgs.forge-mirror}/bin/forge-mirror audit
              ''
            }
          '';

          StandardOutput = "journal";
          StandardError = "journal";
          SyslogIdentifier = "forge-mirror-audit";
        }
        // lib.optionalAttrs alert.enable {
          RuntimeDirectory = "forge-mirror-audit";
          RuntimeDirectoryMode = "0700";
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
