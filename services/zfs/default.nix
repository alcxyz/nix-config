{ options
, config
, lib
, pkgs
, ...
}:
with lib;
with lib.custom; let
  cfg = config.services.zfs;
in
{
  options.services.zfs = with types; {
    enable = mkBoolOpt false "Enable zfs";
  };

  config = mkIf cfg.enable {

    environment.systemPackages = [ pkgs.zfs ];
    boot.supportedFilesystems = [ "zfs" ];
    #boot.zfs.forceImportRoot = false;
    boot.zfs.extraPools = [ "hyperdisk" "fundrive" ];
    networking.hostId = "4e7ded69";

    systemd.services."zfs-import-hyperdisk" = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      script = ''
        if ! /run/current-system/sw/bin/zpool list hyperdisk &>/dev/null; then
          /run/current-system/sw/bin/zpool import hyperdisk
        fi
      '';
      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;
    };

    systemd.services."zfs-import-fundrive" = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      script = ''
        if ! /run/current-system/sw/bin/zpool list fundrive &>/dev/null; then
          /run/current-system/sw/bin/zpool import fundrive
        fi
      '';
      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;
    };

   # services.nfs = {
   #   enable = false;
      # Ensure NFS starts after ZFS pools are imported
      #systemd.services.nfs-server.after = [ "zfs-import-hyperdisk.service" "zfs-import-fundrive.service" ];
   # };

   # services.smb = {
   #   enable = false;
      # Ensure Samba starts after ZFS pools are imported
      #systemd.services.smbd.after = [ "zfs-import-hyperdisk.service" "zfs-import-fundrive.service" ];
      #systemd.services.nmbd.after = [ "zfs-import-hyperdisk.service" "zfs-import-fundrive.service" ];
   # };


  };

}
