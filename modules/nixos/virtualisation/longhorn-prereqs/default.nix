# Host prerequisites for Longhorn volume attachment.
{
  config,
  lib,
  pkgs,
  ...
}: let
  host = config.networking.hostName;
in {
  boot.kernelModules = ["dm_crypt"];

  services.openiscsi = {
    enable = true;
    name = "iqn.2026-05.xyz.alc:${host}";
  };

  # Keep NFS userspace available for Longhorn RWX/share-manager support. The
  # common Linux package set already installs nfs-utils on these hosts.
  #
  # Longhorn runs host checks through nsenter and executes `iscsiadm` by name.
  # On NixOS that binary is not in /usr/bin, so provide the conventional path
  # expected by Longhorn's environment checker.
  systemd.tmpfiles.rules = [
    "L+ /usr/bin/iscsiadm - - - - ${pkgs.openiscsi}/bin/iscsiadm"
  ];

  assertions = [
    {
      assertion = config.k3s.enable or false;
      message = "Longhorn prerequisites should only be enabled on k3s nodes.";
    }
  ];
}
