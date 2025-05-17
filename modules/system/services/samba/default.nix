{
  options
, config
, lib
, username
, ...
}:
with lib;

let
  cfg = config.services.samba; # Keep option path consistent
  # Access the user's primary group assuming username is passed as specialArgs
  userPrimaryGroup = config.users.users.${username}.group;
in
{
  options.services.samba = with types; { # Keep option path consistent
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the Samba server and related services."; # Updated description
    };
  };

  config = mkIf cfg.enable {
    services.samba = {
      enable = true;
      openFirewall = true;
      settings = { 
        global = {
        "workgroup" = "WORKGROUP";
        "server string" = "xyz";
        "netbios name" = "xyz";
        "security" = "user";
        "use sendfile" = "yes";
        "max protocol" = "smb2";
        # note: localhost is the ipv6 localhost ::1
        "hosts allow" = "192.168.1. 127.0.0.1 localhost";
        "hosts deny" = "0.0.0.0/0";
          #"bind interfaces only" = "yes";
        "guest account" = "nobody";
        "map to guest" = "bad user";
        };
        "games" = {
          "path" = "/fundrive/games"; # Assuming /fundrive is a Samba share point
          "browseable" = "yes";
          "read only" = "no";
          "guest ok" = "yes";
          "create mask" = "0755";
          "directory mask" = "0755";
          "force user" = "${username}"; # Use dynamic username
          "force group" = "${userPrimaryGroup}"; # Use dynamic primary group
        };
        "archive" = {
          "path" = "/hyperdisk/archive"; # Assuming /hyperdisk is a Samba share point
          "browseable" = "yes";
          "read only" = "no";
          "guest ok" = "yes";
          "create mask" = "0755";
          "directory mask" = "0755";
          "force user" = "${username}"; # Use dynamic username
          "force group" = "${userPrimaryGroup}"; # Use dynamic primary group
        };
        "vault" = {
          "path" = "/hyperdisk/vault"; # Assuming /hyperdisk is a Samba share point
          "browseable" = "yes";
          "read only" = "no";
          "guest ok" = "yes";
          "create mask" = "0644"; # Check if 0644 is correct for files in a vault
          "directory mask" = "0755";
          "force user" = "${username}"; # Use dynamic username
          "force group" = "${userPrimaryGroup}"; # Use dynamic primary group
        };
        "stash" = {
          "path" = "/hyperdisk/stash"; # Assuming /hyperdisk is a Samba share point
          "browseable" = "yes";
          "read only" = "no";
          "guest ok" = "yes";
          "create mask" = "0644"; # Check if 0644 is correct for files in a stash
          "directory mask" = "0755";
          "force user" = "${username}"; # Use dynamic username
          "force group" = "${userPrimaryGroup}"; # Use dynamic primary group
        };
      };

    };
    services.samba-wsdd = {
      enable = true;
      openFirewall = true;
    };

    # Ensure Samba services wait for ZFS mounts
    systemd.services.smbd.after = [ "zfs-mount.service" ];
    systemd.services.nmbd.after = [ "zfs-mount.service" ];
    systemd.services.samba-wsdd.after = [ "zfs-mount.service" ]; # Add dependency for wsdd as well

    #networking.firewall.enable = true; # These are generally enabled at a higher level
    #networking.firewall.allowPing = true;
  };
}