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
          Directory where the runner's start gate leaves drain-owned,
          game-start-skipped, disk-start-skipped or standby-held while it
          holds the runner back on purpose; a held runner is no failure.
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
      # Only a boot is checked; a switch must not rerun the check.
      restartIfChanged = false;
      environment = {
        NIXFLEET_BOOT_CHECK_WAIT_SECONDS = toString cfg.waitSeconds;
        NIXFLEET_BOOT_CHECK_IGNORED_UNITS = lib.concatStringsSep " " cfg.ignoredFailedUnits;
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
