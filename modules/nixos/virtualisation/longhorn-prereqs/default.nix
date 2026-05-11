# Host prerequisites for Longhorn volume attachment.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  host = config.networking.hostName;
in
{
  boot.kernelModules = [ "dm_crypt" ];

  services.openiscsi = {
    enable = true;
    name = "iqn.2026-05.xyz.alc:${host}";
  };

  # Keep NFS userspace available for Longhorn RWX/share-manager support.
  environment.systemPackages = with pkgs; [
    nfs-utils
    util-linux
  ];

  # Keep conventional FHS command paths available for Longhorn host namespace
  # checks and mount helpers. NixOS stores these binaries under /nix/store,
  # while Longhorn executes them by name/path from CSI helper containers.
  #
  # The same pattern is needed for iscsiadm, mount, and NFS helpers:
  # - RWO volumes need iscsiadm.
  # - RWX volumes need mount plus mount.nfs/umount.nfs.
  systemd.tmpfiles.rules = [
    "L+ /usr/bin/iscsiadm - - - - ${pkgs.openiscsi}/bin/iscsiadm"
    "L+ /usr/bin/mount - - - - ${pkgs.util-linux}/bin/mount"
    "L+ /usr/bin/umount - - - - ${pkgs.util-linux}/bin/umount"
    "L+ /usr/sbin/mount.nfs - - - - ${pkgs.nfs-utils}/bin/mount.nfs"
    "L+ /usr/sbin/umount.nfs - - - - ${pkgs.nfs-utils}/bin/umount.nfs"
    "L+ /sbin/mount.nfs - - - - ${pkgs.nfs-utils}/bin/mount.nfs"
    "L+ /sbin/umount.nfs - - - - ${pkgs.nfs-utils}/bin/umount.nfs"
  ];

  assertions = [
    {
      assertion = config.k3s.enable or false;
      message = "Longhorn prerequisites should only be enabled on k3s nodes.";
    }
  ];
}
