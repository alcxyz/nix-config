# nix-config/modules/nixos/services/forge-mirror-pull/default.nix
#
# Periodically fetches from GitHub and pushes to Forgejo for all repos.
# Safety net for pushes from machines without dual-push configured.
{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:

let
  cfg = config.services.forge-mirror-pull;
in
{
  options.services.forge-mirror-pull = {
    enable = lib.mkEnableOption "forge-mirror GitHub→Forgejo periodic pull sync";

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
        description = "Sops key for the Codeberg token.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.credentials.sopsFile != null;
        message = "services.forge-mirror-pull.credentials.sopsFile must be set privately.";
      }
      {
        assertion = cfg.credentials.forgejoKey != null;
        message = "services.forge-mirror-pull.credentials.forgejoKey must be set privately.";
      }
      {
        assertion = cfg.credentials.githubKey != null;
        message = "services.forge-mirror-pull.credentials.githubKey must be set privately.";
      }
      {
        assertion = cfg.credentials.codebergKey != null;
        message = "services.forge-mirror-pull.credentials.codebergKey must be set privately.";
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

    sops.secrets.forge_mirror_codeberg_token = {
      sopsFile = cfg.credentials.sopsFile;
      key = cfg.credentials.codebergKey;
      owner = cfg.user;
      mode = "0400";
    };

    systemd.services.forge-mirror-pull = {
      description = "Fetch from GitHub and push to Forgejo (forge-mirror pull)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = "root";

        ExecStart = pkgs.writeShellScript "forge-mirror-pull-wrapper" ''
          set -euo pipefail
          export PATH="${
            lib.makeBinPath [
              pkgs.git
              pkgs.coreutils
            ]
          }:$PATH"
          export FORGEJO_TOKEN_FILE="${config.sops.secrets.forge_mirror_forgejo_token.path}"
          export GITHUB_MIRROR_PAT="$(cat ${config.sops.secrets.forge_mirror_github_token.path})"
          export CODEBERG_MIRROR_PAT_FILE="${config.sops.secrets.forge_mirror_codeberg_token.path}"
          export FORGEJO_URL="http://git.local"
          exec ${pkgs.forge-mirror}/bin/forge-mirror pull
        '';

        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "forge-mirror-pull";
      };
    };

    systemd.timers.forge-mirror-pull = {
      description = "Timer for forge-mirror GitHub→Forgejo sync";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        Unit = "forge-mirror-pull.service";
      };
    };
  };
}
