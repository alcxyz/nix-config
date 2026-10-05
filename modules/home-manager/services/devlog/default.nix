# modules/home-manager/services/devlog/default.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.devlog;
  forgejoArgs = lib.optionalString (cfg.forgejo.url != null) " -forgejo-url ${cfg.forgejo.url} -forgejo-user ${cfg.forgejo.user}";
in {
  options.services.devlog = {
    enable = lib.mkEnableOption "Daily devlog generator";

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "05:00";
      description = "Systemd timer schedule (OnCalendar value). Runs in local timezone after the devlog day closes.";
    };

    repoPath = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/src/personal/journal";
      description = "Path to the journal git repo.";
    };

    notifyOnFailure = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Show a desktop notification when a devlog run fails, so failures are not only visible in the journal.";
    };

    forgejo = {
      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://forgejo.example.com";
        description = "Forgejo base URL read as the primary activity source. Null reads GitHub only.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "alcxyz";
        description = "Forgejo user whose own activity is read.";
      };

      tokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = config.home.sessionVariables.FORGEJO_API_TOKEN_FILE or null;
        defaultText = lib.literalExpression "config.home.sessionVariables.FORGEJO_API_TOKEN_FILE or null";
        description = "File holding a Forgejo API token that can read the user's activity feed and repositories.";
      };
    };

    catchUpDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Number of recent days the daily timer scans for missing devlog entries.";
    };

    weekly = {
      enable = lib.mkEnableOption "Weekly devlog summary";

      schedule = lib.mkOption {
        type = lib.types.str;
        default = "Mon 06:00";
        description = "Systemd timer OnCalendar value for the weekly summary.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.forgejo.url == null || cfg.forgejo.tokenFile != null;
          message = "services.devlog.forgejo.url needs services.devlog.forgejo.tokenFile.";
        }
      ];

      systemd.user.services.devlog = {
        Unit =
          {
            Description = "Generate daily devlog from development activity";
          }
          // lib.optionalAttrs cfg.notifyOnFailure {OnFailure = "devlog-failure@%n.service";};
        Service = {
          Type = "oneshot";
          ExecStart = "${pkgs.devlog}/bin/devlog catch-up -repo ${cfg.repoPath} -days ${toString cfg.catchUpDays}${forgejoArgs}";
          StandardOutput = "journal";
          StandardError = "journal";
          Environment =
            [
              "PATH=${lib.makeBinPath [pkgs.git pkgs.gh pkgs.claude-code pkgs.codex-cli pkgs.forge-mirror pkgs.coreutils pkgs.bash pkgs.openssh]}"
              "HOME=${config.home.homeDirectory}"
              "SSH_AUTH_SOCK=%t/ssh-agent"
            ]
            ++ lib.optional (cfg.forgejo.url != null) "FORGEJO_API_TOKEN_FILE=${cfg.forgejo.tokenFile}";
        };
      };

      systemd.user.timers.devlog = {
        Unit.Description = "Timer for daily devlog generator";
        Timer = {
          OnCalendar = cfg.schedule;
          Persistent = true;
          Unit = "devlog.service";
        };
        Install.WantedBy = ["timers.target"];
      };
    }

    (lib.mkIf cfg.notifyOnFailure {
      # Instanced by OnFailure with the failed unit's name.
      systemd.user.services."devlog-failure@" = {
        Unit.Description = "Report failed devlog unit %i";
        Service = {
          Type = "oneshot";
          ExecStart = ''${pkgs.libnotify}/bin/notify-send --urgency=critical --app-name=devlog "%i failed" "Inspect it with: journalctl --user -u %i"'';
        };
      };
    })

    (lib.mkIf cfg.weekly.enable {
      systemd.user.services.devlog-weekly = {
        Unit =
          {
            Description = "Generate weekly devlog summary";
          }
          // lib.optionalAttrs cfg.notifyOnFailure {OnFailure = "devlog-failure@%n.service";};
        Service = {
          Type = "oneshot";
          ExecStart = "${pkgs.devlog}/bin/devlog weekly -repo ${cfg.repoPath}";
          StandardOutput = "journal";
          StandardError = "journal";
          Environment = [
            "PATH=${lib.makeBinPath [pkgs.git pkgs.claude-code pkgs.codex-cli pkgs.forge-mirror pkgs.coreutils pkgs.openssh]}"
            "HOME=${config.home.homeDirectory}"
            "SSH_AUTH_SOCK=%t/ssh-agent"
          ];
        };
      };

      systemd.user.timers.devlog-weekly = {
        Unit.Description = "Timer for weekly devlog summary";
        Timer = {
          OnCalendar = cfg.weekly.schedule;
          Persistent = true;
          Unit = "devlog-weekly.service";
        };
        Install.WantedBy = ["timers.target"];
      };
    })
  ]);
}
