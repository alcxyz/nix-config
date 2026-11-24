# modules/home-manager/programs/rclone/cloud-sync.nix
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.cloud-sync;
  # One systemd ExecStart argument: double-quoted, with backslashes, quotes,
  # specifiers (%) and variable references ($) escaped, so folder names with
  # spaces stay whole.
  systemdArg = s: "\"" + replaceStrings ["\\" "\"" "%" "$"] ["\\\\" "\\\"" "%%" "$$"] s + "\"";
in {
  options.services.cloud-sync = {
    enable = mkEnableOption "Cloud Drive Sync (Google Drive, Dropbox, Nextcloud & OneDrive)";

    syncInterval = mkOption {
      type = types.str;
      default = "hourly";
      description = "Systemd timer interval for sync";
    };

    filterRules = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Declarative rclone filter rules shared by enabled cloud sync jobs.";
    };

    googleDrive = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "Google Drive sync";
          remote = mkOption {
            type = types.str;
            default = "gdrive";
            description = "rclone remote name for Google Drive";
          };
          localPath = mkOption {
            type = types.path;
            description = "Local path to sync";
          };
          syncArgs = mkOption {
            type = types.str;
            default = "--force --recover --resilient --filter-from ${config.xdg.configHome}/rclone/filters.txt";
            description = "Additional rclone sync arguments";
          };
        };
      };
      default = {};
    };

    dropbox = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "Dropbox sync";
          remote = mkOption {
            type = types.str;
            default = "dropbox";
            description = "rclone remote name for Dropbox";
          };
          localPath = mkOption {
            type = types.path;
            description = "Local path to sync";
          };
          syncArgs = mkOption {
            type = types.str;
            default = "--force --recover --resilient --filter-from ${config.xdg.configHome}/rclone/filters.txt";
            description = "Additional rclone sync arguments";
          };
        };
      };
      default = {};
    };

    nextcloud = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "Nextcloud sync";
          remote = mkOption {
            type = types.str;
            default = "nextcloud";
            description = "rclone remote name for Nextcloud";
          };
          localPath = mkOption {
            type = types.path;
            description = "Local path to sync";
          };
          syncArgs = mkOption {
            type = types.str;
            default = "--force --recover --resilient --filter-from ${config.xdg.configHome}/rclone/filters.txt";
            description = "Additional rclone sync arguments";
          };
        };
      };
      default = {};
    };

    oneDrive = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "one-way OneDrive mirror";
          remote = mkOption {
            type = types.str;
            default = "onedrive";
            description = "rclone remote name for OneDrive";
          };
          path = mkOption {
            type = types.str;
            default = "";
            description = "Folder within the remote to mirror; empty mirrors the whole drive, shortcuts to shared folders included";
          };
          localPath = mkOption {
            type = types.path;
            description = "Local mirror of the remote: the next sync deletes files added here and overwrites local edits";
          };
          exclude = mkOption {
            type = types.listOf types.str;
            default = [];
            example = ["/Personal Vault/**"];
            description = "rclone --exclude patterns, for example the Personal Vault, which cannot be listed while locked and would fail every sync";
          };
          syncArgs = mkOption {
            type = types.str;
            default = "--filter-from ${config.xdg.configHome}/rclone/filters.txt";
            description = "Additional rclone sync arguments";
          };
        };
      };
      default = {};
      description = ''
        Mirror OneDrive one way, remote to local, with `rclone sync` rather
        than `bisync`, so nothing local is written to folders others share.
      '';
    };
  };

  config = mkIf cfg.enable {
    home.packages = [pkgs.rclone];

    xdg.configFile."rclone/filters.txt".text =
      lib.concatStringsSep "\n" cfg.filterRules
      + lib.optionalString (cfg.filterRules != []) "\n";

    systemd.user.services = mkMerge [
      (mkIf cfg.googleDrive.enable {
        cloud-sync-gdrive = {
          Unit = {
            Description = "Sync Google Drive with rclone";
            After = ["network-online.target"];
            Wants = ["network-online.target"];
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${pkgs.rclone}/bin/rclone bisync ${cfg.googleDrive.remote}: ${toString cfg.googleDrive.localPath} ${cfg.googleDrive.syncArgs}";
            TimeoutStartSec = "2h";
            StandardOutput = "journal";
            StandardError = "journal";
          };
        };
      })
      (mkIf cfg.dropbox.enable {
        cloud-sync-dropbox = {
          Unit = {
            Description = "Sync Dropbox with rclone";
            After = ["network-online.target"];
            Wants = ["network-online.target"];
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${pkgs.rclone}/bin/rclone bisync ${cfg.dropbox.remote}: ${toString cfg.dropbox.localPath} ${cfg.dropbox.syncArgs}";
            TimeoutStartSec = "2h";
            StandardOutput = "journal";
            StandardError = "journal";
          };
        };
      })
      (mkIf cfg.nextcloud.enable {
        cloud-sync-nextcloud = {
          Unit = {
            Description = "Sync Nextcloud with rclone";
            After = ["network-online.target"];
            Wants = ["network-online.target"];
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${pkgs.rclone}/bin/rclone bisync ${cfg.nextcloud.remote}: ${toString cfg.nextcloud.localPath} ${cfg.nextcloud.syncArgs}";
            TimeoutStartSec = "2h";
            StandardOutput = "journal";
            StandardError = "journal";
          };
        };
      })
      (mkIf cfg.oneDrive.enable {
        cloud-sync-onedrive = {
          Unit = {
            Description = "Mirror OneDrive with rclone (one way)";
            After = ["network-online.target"];
            Wants = ["network-online.target"];
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${pkgs.rclone}/bin/rclone sync ${systemdArg "${cfg.oneDrive.remote}:${cfg.oneDrive.path}"} ${systemdArg (toString cfg.oneDrive.localPath)} ${concatMapStringsSep " " (p: "--exclude ${systemdArg p}") cfg.oneDrive.exclude} ${cfg.oneDrive.syncArgs}";
            TimeoutStartSec = "2h";
            StandardOutput = "journal";
            StandardError = "journal";
          };
        };
      })
    ];

    systemd.user.timers = mkMerge [
      (mkIf cfg.googleDrive.enable {
        cloud-sync-gdrive = {
          Unit.Description = "Run Google Drive sync";
          Timer = {
            OnBootSec = "5min";
            OnUnitActiveSec = cfg.syncInterval;
            Persistent = true;
          };
          Install.WantedBy = ["timers.target"];
        };
      })
      (mkIf cfg.dropbox.enable {
        cloud-sync-dropbox = {
          Unit.Description = "Run Dropbox sync";
          Timer = {
            OnBootSec = "10min";
            OnUnitActiveSec = cfg.syncInterval;
            Persistent = true;
          };
          Install.WantedBy = ["timers.target"];
        };
      })
      (mkIf cfg.nextcloud.enable {
        cloud-sync-nextcloud = {
          Unit.Description = "Run Nextcloud sync";
          Timer = {
            OnBootSec = "15min";
            OnUnitActiveSec = cfg.syncInterval;
            Persistent = true;
          };
          Install.WantedBy = ["timers.target"];
        };
      })
      (mkIf cfg.oneDrive.enable {
        cloud-sync-onedrive = {
          Unit.Description = "Run OneDrive mirror";
          Timer = {
            OnBootSec = "20min";
            OnUnitActiveSec = cfg.syncInterval;
            Persistent = true;
          };
          Install.WantedBy = ["timers.target"];
        };
      })
    ];
  };
}
