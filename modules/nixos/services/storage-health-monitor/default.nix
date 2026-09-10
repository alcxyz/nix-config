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
    {...}: {
      options = {
        name = lib.mkOption {type = lib.types.str;};
        mode = lib.mkOption {
          type = lib.types.enum [
            "active"
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
            Do not report a missing completion timestamp while the matching
            timer is active and has not reached its first trigger yet.
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
        ${lib.boolToString unit.allowPendingFirstTimer}
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
  recentSuccessChecker = pkgs.writeShellApplication {
    name = "storage-health-check-recent-success";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.systemd
    ];
    text = builtins.readFile ./check-recent-success.sh;
  };
  monitorScript = pkgs.writeShellApplication {
    name = "storage-health-monitor";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
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
        suffix="$1"
        base="$(tr -d '\r\n' <${lib.escapeShellArg cfg.pingBaseFile})"
        if [ -z "$base" ]; then
          echo "healthcheck ping base is empty" >&2
          return 1
        fi
        url="$base/${cfg.slug}$suffix?create=1"
        {
          printf 'url = "%s"\n' "$url"
          printf 'data-binary = "@%s"\n' "$report"
        } | curl --config - --silent --show-error --fail --max-time 10 >/dev/null
      }

      check_storage() {
        name="$1"
        kind="$2"
        target="$3"
        maximum_used="$4"
        minimum_free="$5"
        require_rw="$6"
        health=mounted

        if [ "$kind" = zpool ]; then
          if ! values="$(zpool list -Hp -o capacity,free,health "$target" 2>/dev/null)"; then
            record_issue "$name: ZFS pool is unavailable"
            return
          fi
          read -r used free health <<<"$values"
          if [ "$health" != ONLINE ]; then
            record_issue "$name: ZFS health is $health"
          fi
          if [ "$require_rw" = true ] && [ "$(zfs get -H -o value readonly "$target" 2>/dev/null || echo on)" != off ]; then
            record_issue "$name: ZFS pool is read-only"
          fi
        else
          mount_target="$(findmnt -rn -o TARGET --target "$target" 2>/dev/null || true)"
          if [ "$mount_target" != "$target" ]; then
            record_issue "$name: expected filesystem mount is absent"
            return
          fi
          if ! values="$(df -B1 --output=pcent,avail "$target" 2>/dev/null | tail -n 1)"; then
            record_issue "$name: filesystem capacity is unavailable"
            return
          fi
          read -r used free <<<"$values"
          used="''${used%%%}"
          if [ "$require_rw" = true ]; then
            options="$(findmnt -rn -o OPTIONS --target "$target" 2>/dev/null || true)"
            case ",$options," in
              *,rw,*) ;;
              *) record_issue "$name: filesystem is not mounted read-write" ;;
            esac
          fi
        fi

        if [ "$maximum_used" -ge 0 ] && [ "$used" -ge "$maximum_used" ]; then
          record_issue "$name: capacity is ''${used}% (threshold ''${maximum_used}%)"
        fi
        if [ "$minimum_free" -gt 0 ] && [ "$free" -lt "$minimum_free" ]; then
          record_issue "$name: free bytes $free below threshold $minimum_free"
        fi
        printf '%s: used=%s%% free=%s health=%s\n' "$name" "$used" "$free" "$health" >>"$report"
      }

      check_unit() {
        unit="$1"
        mode="$2"
        maximum_age="$3"
        allow_pending_first_timer="$4"

        if [ "$mode" = active ]; then
          if [ "$(systemctl is-active "$unit" 2>/dev/null || true)" != active ]; then
            record_issue "$unit: required service is not active"
          fi
          return
        fi

        marker=${successStateDirectory}/$(printf '%s' "$unit" | sha256sum | cut -d ' ' -f 1)
        if ! issue="$(${lib.getExe recentSuccessChecker} \
          "$unit" "$maximum_age" "$allow_pending_first_timer" \
          "$marker" /proc/uptime)"; then
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
      type = lib.types.str;
      description = "Runtime file containing the private Healthchecks ping base.";
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
