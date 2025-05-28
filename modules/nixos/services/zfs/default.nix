# modules/nixos/services/zfs/default.nix
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
    boot.zfs.devNodes = "/dev/disk/by-id";
    boot.zfs.extraPools = [ "hyperdisk" "fundrive" ];

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
    
  };
}
