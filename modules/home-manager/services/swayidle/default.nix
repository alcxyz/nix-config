{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.swayidle.managed;
  wlrRandr = "${pkgs.wlr-randr}/bin/wlr-randr";
  hyprlock = cfg.lockCommand;
in
{
  options.services.swayidle.managed = {
    enable = mkEnableOption "swayidle idle daemon (managed module)";

    lockTimeout = mkOption {
      type = types.int;
      default = 300;
      description = "Seconds of inactivity before locking with hyprlock.";
    };

    dpmsTimeout = mkOption {
      type = types.int;
      default = 600;
      description = "Seconds of inactivity before turning off displays (DPMS).";
    };

    lockCommand = mkOption {
      type = types.str;
      default = "${pkgs.hyprlock}/bin/hyprlock";
      description = "Command to lock the screen.";
    };

    # Optional: command to run to turn displays on/off. Default uses wlr-randr.
    dpmsOffCommand = mkOption {
      type = types.str;
      default = "${wlrRandr} --off";
      description = "Command to turn off all outputs.";
    };

    dpmsOnCommand = mkOption {
      type = types.str;
      default = "${wlrRandr} --on";
      description = "Command to turn on all outputs.";
    };

    # Optional: handle sleep hooks
    beforeSleepCommand = mkOption {
      type = types.nullOr types.str;
      default = hyprlock;
      description = "Command executed before system sleep (null to disable).";
    };

    afterResumeCommand = mkOption {
      type = types.nullOr types.str;
      default = cfg.dpmsOnCommand;
      description = "Command executed after resume (null to disable).";
    };
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      swayidle
      wlr-randr
      hyprlock
    ];

    # Construct swayidle command line with timeouts
    # swayidle uses multiple --timeout blocks; each can have 'resume' hooks.
    systemd.user.services.swayidle-managed = {
      Unit = {
        Description = "swayidle (managed) for niri";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = let
          lockTimeoutStr = toString cfg.lockTimeout;
          dpmsTimeoutStr = toString cfg.dpmsTimeout;

          lockBlock =
            ''--timeout ${lockTimeoutStr} '${cfg.lockCommand}' '';

          dpmsBlock =
            ''--timeout ${dpmsTimeoutStr} '${cfg.dpmsOffCommand}' --resume '${cfg.dpmsOnCommand}' '';

          beforeSleep =
            optionalString (cfg.beforeSleepCommand != null)
            ''--before-sleep '${cfg.beforeSleepCommand}' '';

          afterResume =
            optionalString (cfg.afterResumeCommand != null)
            ''--resume '${cfg.afterResumeCommand}' '';
        in
          "${pkgs.swayidle}/bin/swayidle -w ${lockBlock} ${dpmsBlock} ${beforeSleep} ${afterResume}";
        Restart = "on-failure";
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
