# nix-config/modules/nixos/services/nixfleet-boot-check/default.nix
#
# After every boot, check that the host runs the intended system, has no
# failed units and runs its CI runners, and record the result in
# /run/nixfleet-boot-check/result, which nixfleet reads after a reboot
# (nix-packages #548).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.nixfleet-boot-check;
  unitName = "nixfleet-boot-check.service";
  bootCheck = pkgs.writeShellApplication {
    name = "nixfleet-boot-check";
    runtimeInputs = [pkgs.coreutils pkgs.gnused pkgs.systemd];
    text = builtins.readFile ./boot-check.sh;
  };
  recheck = pkgs.writeShellApplication {
    name = "nixfleet-boot-check-recheck";
    runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.systemd];
    text = builtins.readFile ./recheck.sh;
  };
  ignoredUnits = lib.concatStringsSep " " cfg.ignoredFailedUnits;
  runnerType = lib.types.submodule {
    options = {
      unit = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9_.@-]+\\.service";
        description = "Runner service that must run after boot.";
      };
      holdMarkerDirectory = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "/[^ =]*");
        default = null;
        description = ''
          Directory where the runner hold or its start gate leaves `held`
          while it keeps the runner stopped on purpose; a held runner is no
          failure.
        '';
      };
    };
  };
in {
  imports = [../storage-health-monitor/default.nix];

  options.services.nixfleet-boot-check = {
    enable =
      lib.mkEnableOption "the nixfleet boot check after every boot"
      // {default = true;};

    package = lib.mkOption {
      type = lib.types.package;
      default = bootCheck;
      readOnly = true;
      description = "The boot check command.";
    };

    ignoredFailedUnits = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[^ ]+");
      default = [];
      description = "Failed units that do not fail the boot check.";
    };

    runnerUnits = lib.mkOption {
      type = lib.types.listOf runnerType;
      default = [];
      description = "CI runner services that must run, or be held by their start gate, after boot.";
    };

    waitSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "How long the check waits for the boot to finish before it checks anyway.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.nixfleet-boot-check = {
      description = "Check that the host booted as intended for nixfleet";
      # The check unit itself never restarts on a switch. The recheck unit
      # below reruns it once when a switch changes the ignored units, or on
      # its first arrival when the check is not a finished pass (failed,
      # reset or still running). So a result can come from a rerun in the
      # middle of a switch, which reads the failed units while the switch is
      # still starting others.
      restartIfChanged = false;
      environment = {
        NIXFLEET_BOOT_CHECK_WAIT_SECONDS = toString cfg.waitSeconds;
        NIXFLEET_BOOT_CHECK_IGNORED_UNITS = ignoredUnits;
        NIXFLEET_BOOT_CHECK_RUNNERS =
          lib.concatMapStringsSep " " (runner: "${runner.unit}=${toString runner.holdMarkerDirectory}") cfg.runnerUnits;
      };
      serviceConfig = {
        # Not oneshot: a oneshot start job stays queued while the check runs,
        # so a boot still finishing would wait for the check while the check
        # waits for the boot. As exec the unit is active while it runs, so the
        # storage monitor cannot count a check in progress as inactive, and
        # fails when the check does.
        Type = "exec";
        RemainAfterExit = true;
        ExecStart = lib.getExe bootCheck;
        RuntimeDirectory = "nixfleet-boot-check";
        RuntimeDirectoryMode = "0755";
        # Keep the result for nixfleet even if the unit is stopped.
        RuntimeDirectoryPreserve = "yes";
        UMask = "0022";
      };
    };

    # A switch that changes the ignored units reruns the check once, so a
    # failure the new list forgives clears without a reboot. Other switches
    # leave the check alone; see recheck.sh.
    systemd.services.nixfleet-boot-check-recheck = {
      description = "Rerun the nixfleet boot check when its ignored units change";
      wantedBy = ["multi-user.target"];
      environment = {
        NIXFLEET_BOOT_CHECK_IGNORED_UNITS = ignoredUnits;
        NIXFLEET_BOOT_CHECK_RECHECK_RECORD = "/run/nixfleet-boot-check-recheck/ignored-units";
        NIXFLEET_BOOT_CHECK_UNIT = unitName;
      };
      serviceConfig = {
        Type = "oneshot";
        # Active after its run, so a switch restarts it only when its unit
        # changes rather than starting it again with every target.
        RemainAfterExit = true;
        ExecStart = lib.getExe recheck;
        RuntimeDirectory = "nixfleet-boot-check-recheck";
        RuntimeDirectoryMode = "0700";
        # The record must outlive the restart that compares against it.
        RuntimeDirectoryPreserve = "yes";
      };
    };

    systemd.timers.nixfleet-boot-check = {
      description = "Check the boot once units have settled";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "2min";
        AccuracySec = "1s";
      };
    };

    # The monitor already pushes failures to the operator. Its first run at
    # five minutes finds the check active (running or passed) or failed.
    services.storage-health-monitor.units = lib.mkIf config.services.storage-health-monitor.enable [
      {
        name = unitName;
        mode = "active";
      }
    ];
  };
}
