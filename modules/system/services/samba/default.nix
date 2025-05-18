{
  options,
  config,
  lib,
  pkgs, # Added pkgs for completeness, though not used directly in this snippet
  username,
  ...
}:
with lib;

let
  # cfg now refers to the standard NixOS option config.services.samba (specifically its .enable attribute)
  cfg = config.services.samba;
  userPrimaryGroup = config.users.users.${username}.group;
in
{
  # Removed options.services.samba block to avoid re-declaration
  # The option services.samba.enable is defined by the main NixOS Samba module.
  # This module now only sets values based on that standard option.

  config = mkIf cfg.enable { # This mkIf now correctly refers to the standard services.samba.enable
    # services.samba.enable = true; # This line is redundant if cfg.enable is already true from the global option.
                                  # The global services.samba.enable = true; in configuration.nix handles enabling it.
                                  # What we want here are the specific *settings* for Samba.

    services.samba.openFirewall = true; # Set specific sub-options
    services.samba.settings = { 
      global = {
      "workgroup" = "WORKGROUP";
      "server string" = "xyz";
      "netbios name" = "xyz";
      "security" = "user";
      "use sendfile" = "yes";
      "max protocol" = "smb2";
      "hosts allow" = "192.168.1. 127.0.0.1 localhost";
      "hosts deny" = "0.0.0.0/0";
      "guest account" = "nobody";
      "map to guest" = "bad user";
      };
      "games" = {
        "path" = "/fundrive/games";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0755";
        "directory mask" = "0755";
        "force user" = "${username}";
        "force group" = "${userPrimaryGroup}";
      };
      "archive" = {
        "path" = "/hyperdisk/archive";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0755";
        "directory mask" = "0755";
        "force user" = "${username}";
        "force group" = "${userPrimaryGroup}";
      };
      "vault" = {
        "path" = "/hyperdisk/vault";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force user" = "${username}";
        "force group" = "${userPrimaryGroup}";
      };
      "stash" = {
        "path" = "/hyperdisk/stash";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force user" = "${username}";
        "force group" = "${userPrimaryGroup}";
      };
    };

    services.samba-wsdd = {
      enable = true;
      openFirewall = true;
    };

    systemd.services.smbd.after = [ "zfs-mount.service" ];
    systemd.services.nmbd.after = [ "zfs-mount.service" ];
    systemd.services.samba-wsdd.after = [ "zfs-mount.service" ];
  };
}
