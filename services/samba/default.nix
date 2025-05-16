{ options
, config
, lib
, ...
}:
with lib;
with lib.custom; let
  cfg = config.services.smb;
in
{
  options.services.smb = with types; {
    enable = mkBoolOpt false "Enable samba";
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
          "path" = "/fundrive/games";
          "browseable" = "yes";
          "read only" = "no";
          "guest ok" = "yes";
          "create mask" = "0755";
          "directory mask" = "0755";
          "force user" = "alc";
          "force group" = "users";
        };
        "archive" = {
          "path" = "/hyperdisk/archive";
          "browseable" = "yes";
          "read only" = "no";
          "guest ok" = "yes";
          "create mask" = "0755";
          "directory mask" = "0755";
          "force user" = "alc";
          "force group" = "users";
        };
        "vault" = {
          "path" = "/hyperdisk/vault";
          "browseable" = "yes";
          "read only" = "no";
          "guest ok" = "yes";
          "create mask" = "0644";
          "directory mask" = "0755";
          "force user" = "alc";
          "force group" = "users";
        };
        "stash" = {
          "path" = "/hyperdisk/stash";
          "browseable" = "yes";
          "read only" = "no";
          "guest ok" = "yes";
          "create mask" = "0644";
          "directory mask" = "0755";
          "force user" = "alc";
          "force group" = "users";
        };
      };

    };
    services.samba-wsdd = {
      enable = true;
      openFirewall = true;
    };

    #networking.firewall.enable = true;
    #networking.firewall.allowPing = true;
  };
}
