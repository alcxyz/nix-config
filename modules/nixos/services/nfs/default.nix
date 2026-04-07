# modules/nixos/services/nfs/default.nix
{ config, lib, pkgs, username, ... }:

with lib;

let
  cfg = config.services.nfs.managed;

  # Build export lines from the shares list
  exportLines = concatMapStringsSep "\n" (s:
    "${s.path}  ${cfg.allowedSubnet}(rw,nohide,insecure,no_subtree_check,all_squash,anonuid=${toString s.anonuid},anongid=${toString s.anongid})"
  ) cfg.shares;

  # Build Avahi service XML entries for Finder discovery
  avahiNfsService = ''
    <?xml version="1.0" standalone='no'?>
    <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
    <service-group>
      <name replace-wildcards="yes">%h NFS</name>
      ${concatMapStringsSep "\n    " (s: ''
    <service>
        <type>_nfs._tcp</type>
        <port>2049</port>
        <txt-record>path=${s.path}</txt-record>
      </service>'') cfg.shares}
    </service-group>
  '';
in
{
  options.services.nfs.managed = {
    enable = mkEnableOption "NFS file sharing with Avahi discovery";

    allowedSubnet = mkOption {
      type = types.str;
      default = "192.168.1.0/24";
      description = "Subnet allowed to access NFS shares.";
    };

    shares = mkOption {
      type = types.listOf (types.submodule {
        options = {
          path = mkOption {
            type = types.str;
            description = "Path to export.";
          };
          anonuid = mkOption {
            type = types.int;
            default = 1000;
            description = "UID for anonymous access (all_squash).";
          };
          anongid = mkOption {
            type = types.int;
            default = 100;
            description = "GID for anonymous access (all_squash).";
          };
        };
      });
      default = [];
      description = "List of NFS shares to export.";
    };
  };

  config = mkIf cfg.enable {
    services.nfs.server = {
      enable = true;
      exports = exportLines;
    };

    # NFS firewall
    networking.firewall.allowedTCPPorts = [ 2049 ];

    # Avahi for mDNS/Bonjour discovery
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      publish = {
        enable = true;
        addresses = true;
        userServices = true;
      };
      extraServiceFiles.nfs = avahiNfsService;
    };

    # Wait for ZFS mounts before serving
    systemd.services.nfs-server.after = [ "zfs-mount.service" ];
  };
}
