# modules/nixos/services/smart-report/default.nix
#
# One-shot SMART report: `smart-report.service` runs `smartctl -x` once per
# boot (and on the activation that adds it) against every NVMe and SATA drive,
# found through /dev/disk/by-id rather than kernel names, which change between
# boots. smartctl -x only reads: it starts no self-test and changes no setting.
#
# The report is world-readable:
#   /var/lib/smart-report/<UTC timestamp>.txt
#   /var/lib/smart-report/latest.txt   (symlink to the newest report)
# Its header lists the drives found and warns when the count differs from
# `expectedDrives`. At boot it waits up to two minutes for that many drives
# to appear before it reports.
#
# The unit stays "active (exited)" after it runs, and a later switch does not
# rerun it. To take a new report:
#   sudo systemctl restart smart-report.service
#   less /var/lib/smart-report/latest.txt
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.smart-report;

  reporter = pkgs.writeShellApplication {
    name = "smart-report";
    runtimeInputs = [pkgs.coreutils pkgs.smartmontools];
    text = builtins.readFile ./smart-report.sh;
  };
in {
  options.services.smart-report = {
    enable = lib.mkEnableOption "a one-shot smartctl -x report of every NVMe and SATA drive";

    expectedDrives = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = ''
        Number of drives the report should find; a different count is flagged
        in the report header. 0 disables the check.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.smart-report = {
      description = "Write a one-shot SMART report of the physical drives";
      wantedBy = ["multi-user.target"];
      after = ["local-fs.target" "systemd-udev-trigger.service"];
      # Run once per boot; rerun by hand (see above).
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe reporter} ${toString cfg.expectedDrives}";
        StateDirectory = "smart-report";
        StateDirectoryMode = "0755";
        UMask = "0022";

        # SATA passthrough (SG_IO) needs CAP_SYS_RAWIO and NVMe admin
        # commands need CAP_SYS_ADMIN; nothing else is kept. smartctl opens
        # SATA and NVMe devices read-only, so the device access is read-only.
        CapabilityBoundingSet = ["CAP_SYS_RAWIO" "CAP_SYS_ADMIN"];
        DevicePolicy = "closed";
        DeviceAllow = ["block-sd r" "block-blkext r" "char-nvme r"];
        NoNewPrivileges = true;
        PrivateNetwork = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        RestrictAddressFamilies = "AF_UNIX";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = ["@system-service"];
      };
    };
  };
}
