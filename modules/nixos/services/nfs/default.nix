# modules/nixos/services/nfs/default.nix
{ config, lib, pkgs, username, ... }:

with lib;

let
  cfg = config.services.nfs.managed;

  # Build export lines — one per share per allowed client
  exportLines = concatMapStringsSep "\n" (s:
    let
      clients = concatMapStringsSep " " (ip:
        "${ip}(rw,nohide,insecure,no_subtree_check,all_squash,anonuid=${toString s.anonuid},anongid=${toString s.anongid})"
      ) (cfg.allowedClients ++ s.allowedClients);
    in "${s.path}  ${clients}"
  ) cfg.shares;

  allowedFirewallClients = unique (
    cfg.allowedClients ++ concatMap (s: s.allowedClients) cfg.shares
  );

  firewallPorts = [
    111
    2049
    20048
  ];

  # Build Avahi service XML entries for Finder discovery
  avahiNfsService = ''
    <?xml version="1.0" standalone='no'?>
    <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
    <service-group>
      <name replace-wildcards="yes">%h NFS</name>
      ${concatMapStringsSep "\n    " (s: ''
    <service>
        <name replace-wildcards="yes">%h NFS ${s.path}</name>
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

    allowedClients = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "List of IPs or subnets allowed to mount NFS shares.";
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
          allowedClients = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Additional IPs or subnets allowed to mount this share.";
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

    # Firewall — only allow NFS/RPC discovery from whitelisted clients.
    networking.firewall.extraCommands = concatMapStringsSep "\n" (ip:
      concatMapStringsSep "\n" (port: ''
        iptables -A nixos-fw -p tcp --dport ${toString port} -s ${ip} -j nixos-fw-accept
        iptables -A nixos-fw -p udp --dport ${toString port} -s ${ip} -j nixos-fw-accept
      '') firewallPorts
    ) allowedFirewallClients;

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

    # Wait for storage mounts before serving their paths.
    systemd.services.nfs-server.after = [ "zfs-mount.service" ];
    systemd.services.nfs-server.unitConfig.RequiresMountsFor = map (share: share.path) cfg.shares;
  };
}
