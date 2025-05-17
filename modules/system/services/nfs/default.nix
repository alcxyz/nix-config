{
  options
, config
, lib
, ...
}:
with lib;
let
  cfg = config.services.nfs;
in
{
  options.services.nfs = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the NFS server system service."; # Updated description
    };
  };

  config = mkIf cfg.enable {
    services.nfs.server = {
      enable = true;
      exports = ''
        /hyperdisk  192.168.1.0/24(rw,nohide,insecure,no_subtree_check) 10.42.0.0/16(rw,nohide,insecure,no_subtree_check)
        /fundrive  192.168.1.0/24(rw,nohide,insecure,no_subtree_check) 10.42.0.0/16(rw,nohide,insecure,no_subtree_check)
        /fundrive/nextcloud/data *(rw,sync,no_root_squash)
        /fundrive/nextcloud/config *(rw,sync,no_root_squash)
      '';
    };

    boot.supportedFilesystems = [ "nfs" ];
    networking.firewall.allowedTCPPorts = [ 2049 ]; #NFS
    networking.firewall.allowedUDPPorts = [ 111 2049 4000 4001 4002 20048 ]; #NFSv3
    services.rpcbind.enable = true;
  };
}
