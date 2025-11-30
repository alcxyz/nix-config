# modules/nixos/services/stash/default.nix
{ config, lib, pkgs, username, ... }:

with lib;

let
  cfg = config.services.stash.managed;
in
{
  options.services.stash.managed = {
    enable = mkEnableOption "Stash infrastructure (users, dirs for Docker)";

    user = mkOption {
      type = types.str;
      default = "stash";
      description = "User for Stash file ownership.";
    };
    group = mkOption {
      type = types.str;
      default = "stash";
      description = "Group for Stash file ownership.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/stash";
      description = "Directory for Stash data (config, database, etc.).";
    };
    mediaDir = mkOption {
      type = types.path;
      default = "/zpool/stash";
      description = "Directory where Stash media is located.";
    };
  };

  config = mkIf cfg.enable {

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      extraGroups = [ "media" "rtorrent" ];
    };
    users.groups.${cfg.group} = {};

    users.users.${username}.extraGroups = [ cfg.group ];

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0750 ${cfg.user} ${cfg.group} - -"
      "d '${cfg.mediaDir}' 0775 ${cfg.user} ${cfg.group} - -"
    ];
  };
}
