# Host prerequisites for Longhorn volume attachment.
{
  config,
  lib,
  pkgs,
  ...
}: let
  host = config.networking.hostName;
  cfg = config.alc.longhornPrereqs;
  storagePath = lib.escapeShellArg cfg.storagePath;
in {
  options.alc.longhornPrereqs = {
    storagePath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/longhorn";
      description = "Host path used by Longhorn for replica storage.";
    };

    storageMountUnit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional systemd mount unit to attempt before protecting the Longhorn storage path.";
    };
  };

  config = {
    boot.kernelModules = ["dm_crypt"];

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

    # A missing data filesystem must not prevent the node from booting, but an
    # ordinary directory on the root filesystem must never become an accidental
    # Longhorn disk. When the configured mount is unavailable, bind an empty
    # directory over the storage path and remount it read-only before k3s starts.
    systemd.services.longhorn-storage-guard = {
      description = "Protect an unavailable Longhorn storage path";
      before = ["k3s.service"];
      after =
        ["local-fs.target"]
        ++ lib.optional (cfg.storageMountUnit != null) cfg.storageMountUnit;
      wants = lib.optional (cfg.storageMountUnit != null) cfg.storageMountUnit;
      path = [
        pkgs.coreutils
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "longhorn-storage-guard";
      };
      script = ''
        install -d -m 0755 ${storagePath}
        install -d -m 0755 "$RUNTIME_DIRECTORY/empty"

        if mountpoint --quiet ${storagePath}; then
          exit 0
        fi

        mount --bind "$RUNTIME_DIRECTORY/empty" ${storagePath}
        mount --options remount,bind,ro ${storagePath}
        touch "$RUNTIME_DIRECTORY/fallback-mounted"
      '';
      preStop = ''
        if test -e "$RUNTIME_DIRECTORY/fallback-mounted"; then
          umount ${storagePath}
        fi
      '';
    };

    systemd.services.k3s = {
      requires = ["longhorn-storage-guard.service"];
      after = ["longhorn-storage-guard.service"];
    };

    assertions = [
      {
        assertion = config.k3s.enable or false;
        message = "Longhorn prerequisites should only be enabled on k3s nodes.";
      }
    ];
  };
}
