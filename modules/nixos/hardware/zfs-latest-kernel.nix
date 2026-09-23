{pkgs, ...}: {
  # Keep stable userspace tools and kernel modules matched through nixpkgs.
  # See ADR-0035; importing or upgrading any pool remains a separate
  # host-specific operation.
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.zfs.package = pkgs.zfs_2_4;
  boot.supportedFilesystems = ["zfs"];
  boot.zfs.devNodes = "/dev/disk/by-id";
  boot.zfs.forceImportRoot = false;
}
