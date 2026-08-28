{pkgs, ...}: let
  zfsPackage = pkgs.openzfs_7_1;
  zfsKernelPackages = pkgs.linuxPackages_latest.extend (
    _final: kernelPackages: {
      openzfs_7_1 = zfsPackage.override {
        configFile = "kernel";
        kernel = kernelPackages.kernel;
      };
    }
  );
in {
  # Keep the userspace tools and kernel module on the same reviewed OpenZFS
  # revision. See ADR-0035; importing or upgrading any pool remains a separate
  # host-specific operation.
  boot.kernelPackages = zfsKernelPackages;
  boot.zfs.package = zfsPackage;
  boot.supportedFilesystems = ["zfs"];
  boot.zfs.devNodes = "/dev/disk/by-id";
  boot.zfs.forceImportRoot = false;
}
