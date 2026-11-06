# nix-config/modules/nixos/services/storage-health-monitor/default.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.storage-health-monitor;
  checkType = lib.types.submodule (
    {...}: {
      options = {
        name = lib.mkOption {type = lib.types.str;};
        kind = lib.mkOption {
          type = lib.types.enum [
            "filesystem"
            "zpool"
          ];
        };
        target = lib.mkOption {type = lib.types.str;};
        maximumUsedPercent = lib.mkOption {
          type = lib.types.nullOr (lib.types.ints.between 1 100);
          default = 80;
          description = ''
            Optional utilization threshold. Set to null when a metrics system
            such as Beszel owns percentage-based resource alerts.
          '';
        };
        minimumFreeBytes = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 0;
        };
        requireReadWrite = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
      };
    }
  );
  unitType = lib.types.submodule (
    {config, ...}: {
      options = {
        name = lib.mkOption {type = lib.types.str;};
        mode = lib.mkOption {
          type = lib.types.enum [
            "active"
            "active-not-degraded"
            "recent-success"
          ];
        };
        maximumAgeSeconds = lib.mkOption {
          type = lib.types.ints.positive;
          default = 129600;
        };
        allowPendingFirstTimer = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Allow missing or valid stale success only before the matching timer's
            first trigger this boot, within its scheduled deadline plus accuracy
            and pendingFirstTimerMaximumAgeSeconds. Invalid state and current
            failures still fail immediately. No post-trigger grace is granted.
          '';
        };
        pendingFirstTimerMaximumAgeSeconds = lib.mkOption {
          type = lib.types.ints.positive;
          default = config.maximumAgeSeconds;
          description = ''
            Maximum boot age (including suspend) for the opt-in first-timer
            exception. Timer restart or rescheduling cannot extend this cap.
            Set it to cover startup scheduling, randomized delay and accuracy.
          '';
        };
      };
    }
  );
  renderMaximumUsedPercent = check:
    if check.maximumUsedPercent == null
    then "-1"
    else toString check.maximumUsedPercent;
  renderedChecks =
    lib.concatMapStringsSep "\n" (check: ''
      check_storage \
        ${lib.escapeShellArg check.name} \
        ${lib.escapeShellArg check.kind} \
        ${lib.escapeShellArg check.target} \
        ${renderMaximumUsedPercent check} \
        ${toString check.minimumFreeBytes} \
        ${lib.boolToString check.requireReadWrite}
    '')
    cfg.checks;
  renderedUnits =
    lib.concatMapStringsSep "\n" (unit: ''
      check_unit \
        ${lib.escapeShellArg unit.name} \
        ${lib.escapeShellArg unit.mode} \
        ${toString unit.maximumAgeSeconds} \
        ${lib.boolToString unit.allowPendingFirstTimer} \
        ${toString unit.pendingFirstTimerMaximumAgeSeconds}
    '')
    cfg.units;
  recentSuccessUnits = builtins.filter (unit: unit.mode == "recent-success") cfg.units;
  successStateDirectory = "/var/lib/storage-health-monitor/success";
  successMarker = unit: "${successStateDirectory}/${builtins.hashString "sha256" unit.name}";
  successRecorder = pkgs.writeShellApplication {
    name = "storage-health-record-success";
    runtimeInputs = [pkgs.coreutils];
    text = builtins.readFile ./record-success.sh;
  };
  activeUnitChecker = pkgs.writeShellApplication {
    name = "storage-health-check-active-unit";
    runtimeInputs = [pkgs.systemd];
    text = builtins.readFile ./check-active-unit.sh;
  };
  recentSuccessChecker = pkgs.writeShellApplication {
    name = "storage-health-check-recent-success";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.systemd
      pendingTimerChecker
    ];
    text = builtins.readFile ./check-recent-success.sh;
  };
  pendingTimerChecker = pkgs.writeShellApplication {
    name = "storage-health-check-pending-first-timer";
    runtimeInputs = [pkgs.python3 pkgs.systemd];
    text = ''exec python3 ${./check-pending-first-timer.py} "$@"'';
  };
  monitorScript = pkgs.writeShellApplication {
    name = "storage-health-monitor";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.python3
      pkgs.gawk
      pkgs.gnugrep
      pkgs.systemd
      pkgs.util-linux
      config.boot.zfs.package
    ];
    text = ''
      report=/run/storage-health-monitor/report
      install -d -m 0700 /run/storage-health-monitor
      : >"$report"
      issues=0

      record_issue() {
        printf '%s\n' "$1" >>"$report"
        issues=$((issues + 1))
      }

      send_ping() {
        # Bound DNS and the whole response, including a trickling peer.
        timeout --signal=KILL 10s python3 ${./send-ping.py} \
          ${
        if cfg.pingUrlFile != null
        then "check"
        else "base"
      } \
          ${lib.escapeShellArg (
        if cfg.pingUrlFile != null
        then cfg.pingUrlFile
        else cfg.pingBaseFile
      )} \
          ${lib.escapeShellArg cfg.slug} "$1" "$report"
      }

      ${builtins.readFile ./check-storage.sh}

      check_unit() {
        unit="$1"
        mode="$2"
        maximum_age="$3"
        allow_pending_first_timer="$4"
        pending_first_timer_maximum_age="$5"

        if [ "$mode" = active ] || [ "$mode" = active-not-degraded ]; then
          if ! issue="$(${lib.getExe activeUnitChecker} "$unit" "$mode")"; then
            record_issue "''${issue:-$unit: active-unit check failed without a reason}"
          fi
          return
        fi

        marker=${successStateDirectory}/$(printf '%s' "$unit" | sha256sum | cut -d ' ' -f 1)
        if ! issue="$(${lib.getExe recentSuccessChecker} \
          "$unit" "$maximum_age" "$allow_pending_first_timer" \
          "$marker" /proc/uptime "$pending_first_timer_maximum_age")"; then
          record_issue "''${issue:-$unit: recent-success check failed without a reason}"
        fi
      }

      send_ping /start || true
      ${renderedChecks}
      ${renderedUnits}

      if [ "$issues" -gt 0 ]; then
        send_ping /fail || true
        cat "$report" >&2
        exit 1
      fi
      send_ping ""
      cat "$report"
    '';
  };
in {
  options.services.storage-health-monitor = {
    enable = lib.mkEnableOption "host storage capacity, health, and backup freshness monitoring";
    pingBaseFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Runtime file containing the private Healthchecks HTTPS ping base.
        Embedded credentials, query strings and fragments are rejected.
        Also supplies the default project base for separate runner alerts.
      '';
    };
    pingUrlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Runtime file containing one check's HTTPS ping URL. When set, takes
        precedence over pingBaseFile and does not auto-provision by slug.
        Embedded credentials, query strings and fragments are rejected.
        Separate slug-based consumers, including runner alerts, still need
        their own project ping base.
      '';
    };
    slug = lib.mkOption {
      type = lib.types.strMatching "[a-z0-9-]+";
      default = "storage-${config.networking.hostName}";
    };
    interval = lib.mkOption {
      type = lib.types.str;
      default = "15m";
    };
    checks = lib.mkOption {
      type = lib.types.listOf checkType;
      default = [];
    };
    units = lib.mkOption {
      type = lib.types.listOf unitType;
      default = [];
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.pingUrlFile != null || cfg.pingBaseFile != null;
        message = "storage-health-monitor requires pingUrlFile or pingBaseFile";
      }
      {
        assertion = lib.all (unit: let
          serviceConfig = config.systemd.services.${lib.removeSuffix ".service" unit.name}.serviceConfig;
        in
          (serviceConfig.User or "root")
          == "root"
          && !(serviceConfig.DynamicUser or false)
          && (serviceConfig.Type or "") == "oneshot"
          && !(serviceConfig.RemainAfterExit or false))
        recentSuccessUnits;
        message = "storage-health-monitor recent-success units must be root-run oneshot services that become inactive after completion";
      }
    ];

    systemd.tmpfiles.rules = [
      "d /var/lib/storage-health-monitor 0700 root root - -"
      "d ${successStateDirectory} 0700 root root - -"
    ];

    systemd.services = lib.mkMerge (
      [
        {
          storage-health-monitor = {
            description = "Check storage capacity, health, and backup freshness";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = lib.getExe monitorScript;
              UMask = "0077";
            };
          };
        }
      ]
      ++ map (unit: {
        ${lib.removeSuffix ".service" unit.name}.serviceConfig.ExecStopPost = lib.mkAfter [
          "${lib.getExe successRecorder} ${lib.escapeShellArg (successMarker unit)}"
        ];
      })
      recentSuccessUnits
    );
    systemd.timers.storage-health-monitor = {
      description = "Frequent storage and backup health checks";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "5m";
        OnUnitActiveSec = cfg.interval;
        Persistent = false;
        RandomizedDelaySec = "0";
      };
    };
  };
}
