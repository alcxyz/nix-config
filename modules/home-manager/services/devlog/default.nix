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
      default = "23:00";
      description = "Systemd timer schedule (OnCalendar value). Runs in local timezone.";
    };

    repoPath = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/git/journal";
      description = "Path to the journal git repo.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.devlog = {
      Unit.Description = "Generate daily devlog from GitHub activity";
      Service = {
        Type = "oneshot";
        ExecStart = "${cfg.repoPath}/devlog.sh";
        StandardOutput = "journal";
        StandardError = "journal";
        Environment = [
          "PATH=${lib.makeBinPath [ pkgs.git pkgs.gh pkgs.claude-code pkgs.coreutils pkgs.bash pkgs.openssh ]}"
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
  };
}
