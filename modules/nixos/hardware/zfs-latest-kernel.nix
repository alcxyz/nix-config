{pkgs, ...}: {
  # Keep the pinned Linux 7.3 candidate's userspace and module matched.
  # See ADR-0035; importing or upgrading any pool remains a separate
  # host-specific operation.
  boot.kernelPackages = pkgs.linuxPackages_latest.extend (final: _prev: {
    openzfs_7_3 = pkgs.openzfs_7_3.override {
      kernel = final.kernel;
      configFile = "kernel";
    };
  });
  boot.zfs.package = pkgs.openzfs_7_3;
  boot.supportedFilesystems = ["zfs"];
  boot.zfs.devNodes = "/dev/disk/by-id";
  boot.zfs.forceImportRoot = false;
}
