# Host prerequisites for Longhorn volume attachment.
{
  config,
  lib,
  ...
}: let
  host = config.networking.hostName;
in {
  services.openiscsi = {
    enable = true;
    name = "iqn.2026-05.xyz.alc:${host}";
  };

  # Keep NFS userspace available for Longhorn RWX/share-manager support. The
  # common Linux package set already installs nfs-utils on these hosts.
  assertions = [
    {
      assertion = config.k3s.enable or false;
      message = "Longhorn prerequisites should only be enabled on k3s nodes.";
    }
  ];
}
