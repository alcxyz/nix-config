# modules/home-manager/services/paperless-filetype-index/default.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.services.paperless-filetype-index;
in
{
  options.services.paperless-filetype-index = {
    enable = lib.mkEnableOption "Paperless filetype index builder";

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "Systemd timer schedule (OnCalendar value).";
      example = "*:0/30";
    };

    mediaVolume = lib.mkOption {
      type = lib.types.str;
      default = "arq_media";
      description = "Docker volume name containing Paperless media.";
    };

    indexVolume = lib.mkOption {
      type = lib.types.str;
      default = "paperless_filetype_index";
      description = "Docker volume name for the filetype index output.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.paperless-filetype-index = {
      Unit.Description = "Build symlink index of non-PDF Paperless files by type";
      Service = {
        Type = "oneshot";
        ExecStart = "${pkgs.paperless-filetype-index}/bin/paperless-filetype-index --media-volume ${cfg.mediaVolume} --index-volume ${cfg.indexVolume}";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    systemd.user.timers.paperless-filetype-index = {
      Unit.Description = "Timer for Paperless filetype index builder";
      Timer = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        Unit = "paperless-filetype-index.service";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
