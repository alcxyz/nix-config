# Host prerequisites for Longhorn volume attachment.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  host = config.networking.hostName;
  cfg = config.alc.longhornPrereqs;
  storageTargets = [
    {
      path = cfg.storagePath;
      mountUnit = cfg.storageMountUnit;
    }
  ]
  ++ cfg.additionalStorageTargets;
  storageMountUnits = lib.unique (
    lib.filter (unit: unit != null) (map (target: target.mountUnit) storageTargets)
  );
  guardStorageTargets = lib.concatImapStringsSep "\n" (
    index: target:
    let
      storagePath = lib.escapeShellArg target.path;
      fallback = "$RUNTIME_DIRECTORY/empty-${toString index}";
      marker = "$RUNTIME_DIRECTORY/fallback-${toString index}-mounted";
    in
    ''
      install -d -m 0755 ${storagePath}
      install -d -m 0755 "${fallback}"

      if ! mountpoint --quiet ${storagePath}; then
        mount --bind "${fallback}" ${storagePath}
        mount --options remount,bind,ro ${storagePath}
        touch "${marker}"
      fi
    ''
  ) storageTargets;
  unguardStorageTargets = lib.concatImapStringsSep "\n" (
    index: target:
    let
      storagePath = lib.escapeShellArg target.path;
      marker = "$RUNTIME_DIRECTORY/fallback-${toString index}-mounted";
    in
    ''
      if test -e "${marker}"; then
        umount ${storagePath}
      fi
    ''
  ) storageTargets;
in
{
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

    additionalStorageTargets = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.str;
              description = "Additional host path used by Longhorn for replica storage.";
            };
            mountUnit = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional systemd mount unit for the additional Longhorn storage path.";
            };
          };
        }
      );
      default = [ ];
      description = "Additional Longhorn storage paths protected against accidental root-filesystem use.";
    };
  };

  config = {
    boot.kernelModules = [ "dm_crypt" ];

    services.openiscsi = {
      enable = true;
      name = "iqn.2026-05.xyz.alc:${host}";
    };

    # Keep NFS userspace available for Longhorn RWX/share-manager support.
    environment.systemPackages = with pkgs; [
      cryptsetup
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
      "L+ /usr/bin/cryptsetup - - - - ${pkgs.cryptsetup}/bin/cryptsetup"
      "L+ /usr/bin/mount - - - - ${pkgs.util-linux}/bin/mount"
      "L+ /usr/bin/umount - - - - ${pkgs.util-linux}/bin/umount"
      "L+ /usr/sbin/mount.nfs - - - - ${pkgs.nfs-utils}/bin/mount.nfs"
      "L+ /usr/sbin/umount.nfs - - - - ${pkgs.nfs-utils}/bin/umount.nfs"
      "L+ /sbin/mount.nfs - - - - ${pkgs.nfs-utils}/bin/mount.nfs"
      "L+ /sbin/umount.nfs - - - - ${pkgs.nfs-utils}/bin/umount.nfs"
    ];

    # Open-iSCSI 2.1.12 rejects node records written by older releases when
    # they contain this removed field. The records are connection cache, and
    # removing only the unsupported key does not alter live kernel sessions.
    system.activationScripts.longhornOpeniscsiNodeRecordCompatibility.text = ''
      if test -d /etc/iscsi/nodes; then
        ${pkgs.findutils}/bin/find /etc/iscsi/nodes -type f -name default \
          -exec ${pkgs.gnused}/bin/sed -i \
            '/^node\.session\.conn_reopen_log_freq[[:space:]]*=/d' {} +
      fi
    '';

    # A missing data filesystem must not prevent the node from booting, but an
    # ordinary directory on the root filesystem must never become an accidental
    # Longhorn disk. When the configured mount is unavailable, bind an empty
    # directory over the storage path and remount it read-only before k3s starts.
    systemd.services.longhorn-storage-guard = {
      description = "Protect an unavailable Longhorn storage path";
      before = [ "k3s.service" ];
      after = [ "local-fs.target" ] ++ storageMountUnits;
      wants = storageMountUnits;
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
        ${guardStorageTargets}
      '';
      preStop = ''
        ${unguardStorageTargets}
      '';
    };

    systemd.services.k3s = {
      requires = [ "longhorn-storage-guard.service" ];
      after = [ "longhorn-storage-guard.service" ];
    };

    assertions = [
      {
        assertion = config.k3s.enable or false;
        message = "Longhorn prerequisites should only be enabled on k3s nodes.";
      }
    ];
  };
}
