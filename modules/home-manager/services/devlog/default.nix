# modules/home-manager/services/devlog/default.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.services.devlog;
in
{
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
      systemd.user.services.devlog = {
        Unit.Description = "Generate daily devlog from GitHub activity";
        Service = {
          Type = "oneshot";
          ExecStart = "${pkgs.devlog}/bin/devlog catch-up -repo ${cfg.repoPath} -days ${toString cfg.catchUpDays}";
          StandardOutput = "journal";
          StandardError = "journal";
          Environment = [
            "PATH=${lib.makeBinPath [ pkgs.git pkgs.gh pkgs.claude-code pkgs.codex pkgs.forge-mirror pkgs.coreutils pkgs.bash pkgs.openssh ]}"
            "HOME=${config.home.homeDirectory}"
            "SSH_AUTH_SOCK=%t/ssh-agent"
          ];
        };
      };

      systemd.user.timers.devlog = {
        Unit.Description = "Timer for daily devlog generator";
        Timer = {
          OnCalendar = cfg.schedule;
          Persistent = true;
          Unit = "devlog.service";
        };
        Install.WantedBy = [ "timers.target" ];
      };
    }

    (lib.mkIf cfg.weekly.enable {
      systemd.user.services.devlog-weekly = {
        Unit.Description = "Generate weekly devlog summary";
        Service = {
          Type = "oneshot";
          ExecStart = "${pkgs.devlog}/bin/devlog weekly -repo ${cfg.repoPath}";
          StandardOutput = "journal";
          StandardError = "journal";
          Environment = [
            "PATH=${lib.makeBinPath [ pkgs.git pkgs.claude-code pkgs.codex pkgs.forge-mirror pkgs.coreutils pkgs.openssh ]}"
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
        Install.WantedBy = [ "timers.target" ];
      };
    })
  ]);
}
