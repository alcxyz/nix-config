# modules/home-manager/services/nix-stale-gcroots/default.nix
#
# Removes stale indirect GC roots created by `nix build` result links and
# nix-direnv, so abandoned checkouts stop pinning store paths. Only the root
# symlinks are removed; nix-direnv recreates its roots on the next load. Tool
# state roots under ~/.local/state and ~/.cache are never touched. See ADR-0013.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.nix-stale-gcroots;
  home = config.home.homeDirectory;

  prune = pkgs.writeShellApplication {
    name = "nix-stale-gcroots";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      max_age=$(( ${toString cfg.maxAgeDays} * 86400 ))
      now=$(date +%s)
      uid=$(id -u)
      removed=0

      for registry in /nix/var/nix/gcroots/auto/*; do
        target=$(readlink "$registry") || continue
        case "$target" in
          ${home}/.local/state/* | ${home}/.cache/*) continue ;;
          ${home}/* | /tmp/*) ;;
          *) continue ;;
        esac
        case "$target" in
          */.direnv/*) ;;
          */result | */result-*) ;;
          *) continue ;;
        esac
        [ -L "$target" ] || continue
        # stat without -L describes the link itself, not the store path.
        [ "$(stat -c %u -- "$target")" = "$uid" ] || continue

        mtime=$(stat -c %Y -- "$target") || continue
        if [ $(( now - mtime )) -gt "$max_age" ]; then
          rm -f -- "$target"
          echo "removed $target"
          removed=$(( removed + 1 ))
        fi
      done

      echo "removed $removed stale GC root link(s) older than ${toString cfg.maxAgeDays} days"
    '';
  };
in {
  options.services.nix-stale-gcroots = {
    enable = lib.mkEnableOption "daily removal of stale result and nix-direnv GC roots";

    maxAgeDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Remove root links whose symlink is older than this many days.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {home.packages = [prune];}

    (lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
      systemd.user.services.nix-stale-gcroots = {
        Unit.Description = "Remove stale result and nix-direnv GC roots";
        Service = {
          Type = "oneshot";
          ExecStart = lib.getExe prune;
          Nice = 10;
          IOSchedulingClass = "idle";
        };
      };

      # Paths released here are collected by the next scheduled nix-gc run.
      systemd.user.timers.nix-stale-gcroots = {
        Unit.Description = "Daily stale GC root cleanup";
        Timer = {
          OnCalendar = "*-*-* 00:30:00";
          Persistent = true;
          Unit = "nix-stale-gcroots.service";
        };
        Install.WantedBy = ["timers.target"];
      };
    })

    (lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
      launchd.agents.nix-stale-gcroots = {
        enable = true;
        config = {
          ProgramArguments = [(lib.getExe prune)];
          StartCalendarInterval = [
            {
              Hour = 1;
              Minute = 30;
            }
          ];
          ProcessType = "Background";
          LowPriorityIO = true;
          StandardOutPath = "${home}/Library/Logs/nix-stale-gcroots.log";
          StandardErrorPath = "${home}/Library/Logs/nix-stale-gcroots.log";
        };
      };
    })
  ]);
}
