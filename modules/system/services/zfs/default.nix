{
  options
, config
, lib
, pkgs
, ...
}:
with lib;

let
  cfg = config.services.zfs; # Keep option path consistent
in
{
  options.services.zfs = with types; { # Keep option path consistent
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable ZFS support and related services."; # Updated description
    };
  };

  config = mkIf cfg.enable {

    environment.systemPackages = [ pkgs.zfs ];
    boot.supportedFilesystems = [ "zfs" ];
    #boot.zfs.forceImportRoot = false; # Keep commented out if not used
    boot.zfs.extraPools = [ "hyperdisk" "fundrive" ]; # Define your ZFS pools
    networking.hostId = "4e7ded69"; # Ensure this matches your host's ID if needed for ZFS

    # Systemd services to import ZFS pools on boot (commented out)
    # systemd.services."zfs-import-hyperdisk" = {
    #   after = [ "network-online.target" ]; # Depends on network being online
    #   wants = [ "network-online.target" ];
    #   script = ''
    #     if ! ${pkgs.zfs}/bin/zpool list hyperdisk &>/dev/null; then
    #       ${pkgs.zfs}/bin/zpool import hyperdisk
    #     fi
    #   '';
    #   serviceConfig.Type = "oneshot";
    #   serviceConfig.RemainAfterExit = true;
    # };

    # systemd.services."zfs-import-fundrive" = {
    #   after = [ "network-online.target" ];
    #   wants = [ "network-online.target" ];
    #   script = ''
    #     if ! ${pkgs.zfs}/bin/zpool list fundrive &>/dev/null; then
    #       ${pkgs.zfs}/bin/zpool import fundrive
    #     fi
    #   '';
    #   serviceConfig.Type = "oneshot";
    #   serviceConfig.RemainAfterExit = true;
    # };

   # services.nfs = { enable = false; }; # These should be enabled/configured in their own modules
   # services.smb = { enable = false; }; # These should be enabled/configured in their own modules

    # Dependencies for other services on ZFS pools being imported:
    # This needs to be added to the respective service modules (NFS, Samba) if they depend on ZFS.
    # Example (would go in modules/system/services/nfs/default.nix):
    # systemd.services.nfs-server.after = [ "zfs-import-hyperdisk.service" "zfs-import-fundrive.service" ];
    # Example (would go in modules/system/services/samba/default.nix):
    # systemd.services.smbd.after = [ "zfs-import-hyperdisk.service" "zfs-import-fundrive.service" ];
    # systemd.services.nmbd.after = [ "zfs-import-hyperdisk.service" "zfs-import-fundrive.service" ];

  };
}
