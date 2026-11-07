# modules/home-manager/services/home-cache-trim/default.nix
#
# Weekly removal of old files from selected ~/.cache directories, such as
# browser and mail caches, so they stop filling the system pool. Only files
# older than maxAgeDays are deleted and directories are kept. Optionally prunes
# unused Podman images. Containers, volumes and the rest of the system are
# never pruned. Linux only.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.home-cache-trim;

  trim = pkgs.writeShellApplication {
    name = "home-cache-trim";
    runtimeInputs = [pkgs.coreutils pkgs.findutils];
    text = ''
      max_age=${toString cfg.maxAgeDays}
      cache_names=(${lib.escapeShellArgs cfg.cacheDirectories})
      status=0

      # Size of a directory in MiB, or nothing when it cannot be read.
      size_mib() {
        du -sm -- "$1" 2>/dev/null | cut -f1 || true
      }

      for name in "''${cache_names[@]}"; do
        dir="$HOME/.cache/$name"
        if [ ! -d "$dir" ]; then
          echo "skipping $dir: not present"
          continue
        fi
        before=$(size_mib "$dir")
        if ! find "$dir" -xdev -ignore_readdir_race -type f -mtime "+$max_age" -delete; then
          echo "could not trim all of $dir" >&2
          status=1
        fi
        after=$(size_mib "$dir")
        echo "trimmed $dir: ''${before:-?} MiB -> ''${after:-?} MiB"
      done

      ${lib.optionalString (cfg.podmanImageMaxAgeDays != null) ''
        if command -v podman >/dev/null 2>&1; then
          # The until filter applies to image creation time.
          if ! podman image prune --all --force --filter "until=${toString (cfg.podmanImageMaxAgeDays * 24)}h" >/dev/null; then
            echo "podman image prune failed" >&2
            status=1
          fi
        else
          echo "podman not on PATH; skipping image prune"
        fi
      ''}

      exit "$status"
    '';
  };
in {
  options.services.home-cache-trim = {
    enable = lib.mkEnableOption "weekly removal of old files from selected ~/.cache directories";

    cacheDirectories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["BraveSoftware" "thunderbird"];
      description = "Directories under ~/.cache whose files older than maxAgeDays are removed.";
    };

    maxAgeDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Remove cache files whose modification time is older than this many days.";
    };

    podmanImageMaxAgeDays = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "When set, prune unused Podman images created more than this many days ago.";
    };
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isLinux) {
    home.packages = [trim];

    systemd.user.services.home-cache-trim = {
      Unit.Description = "Trim old files from selected caches";
      Service = {
        Type = "oneshot";
        ExecStart = lib.getExe trim;
        Nice = 15;
        IOSchedulingClass = "idle";
        # Rootless Podman needs the setuid helpers in /run/wrappers/bin. The
        # script's runtimeInputs still come first in PATH.
        Environment = "PATH=/run/wrappers/bin:/run/current-system/sw/bin";
      };
    };

    systemd.user.timers.home-cache-trim = {
      Unit.Description = "Weekly cache trim";
      Timer = {
        OnCalendar = "Sun *-*-* 04:15:00";
        Persistent = true;
        Unit = "home-cache-trim.service";
      };
      Install.WantedBy = ["timers.target"];
    };
  };
}
