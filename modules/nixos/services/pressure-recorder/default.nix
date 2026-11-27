# modules/nixos/services/pressure-recorder/default.nix
#
# Off-host record of pressure stall information (PSI) and disk statistics, so
# the samples taken before a host stops responding survive on another host.
#
# Sender: `pressure-recorder.service` samples /proc/pressure/{cpu,io,memory}
# and the whole-disk lines of /proc/diskstats every `interval` seconds and
# logs them into its own journal namespace (`pressure`, bounded by
# `localMaxUse`). `systemd-journal-upload.service` streams only that namespace
# to the receiver over HTTP; it keeps its cursor in
# /var/lib/private/systemd/journal-upload/state and catches up after an outage.
#
# Receiver: `systemd-journal-remote.socket` listens on `listenAddress:port`
# only, accepts connections only from `allowedSources` (socket IP filter and
# firewall rule), and writes one journal file per sender under
# /var/log/journal/remote/, bounded by `maxUse`.
#
# Line format (journal identifier `pressure-recorder`):
#   psi <cpu|io|memory> some avg10=.. avg60=.. avg300=.. total=.. full ...
#   disk <name> <the kernel's diskstats fields after the device name>
# The disk fields follow Documentation/admin-guide/iostats.rst: reads
# completed, reads merged, sectors read, ms reading, writes completed, writes
# merged, sectors written, ms writing, I/Os in progress, ms doing I/O,
# weighted ms doing I/O, then discard and flush counters.
#
# Reading the record on the receiver (as root, or as a user listed in
# `receiver.readers`, without sudo):
#   journalctl -D /var/log/journal/remote -t pressure-recorder --since -1h
#   journalctl -D /var/log/journal/remote -t pressure-recorder -n 200
#   journalctl -D /var/log/journal/remote -t pressure-recorder \
#     --since '2026-01-01 03:00' --until '2026-01-01 03:30' -o short-precise
# The last lines before a gap in the timestamps are the final samples the
# sender shipped. On the sender, `journalctl --namespace=pressure` shows the
# local copy and `systemctl status systemd-journal-upload` the shipping state.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.pressure-recorder;
  namespace = "pressure";

  sampler = pkgs.writeShellApplication {
    name = "pressure-recorder-sample";
    runtimeInputs = [pkgs.coreutils];
    text = builtins.readFile ./sample.sh;
  };

  receiverPort = toString cfg.receiver.port;
in {
  options.services.pressure-recorder = {
    sender = {
      enable = lib.mkEnableOption "sampling pressure and disk statistics and shipping them to a journal receiver";

      url = lib.mkOption {
        type = lib.types.str;
        example = "http://192.0.2.10:19532";
        description = "URL of the systemd-journal-remote receiver.";
      };

      interval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "Seconds between samples.";
      };

      localMaxUse = lib.mkOption {
        type = lib.types.str;
        default = "64M";
        description = "Disk space the local `pressure` journal namespace may use.";
      };
    };

    receiver = {
      enable = lib.mkEnableOption "receiving shipped journals with systemd-journal-remote";

      listenAddress = lib.mkOption {
        type = lib.types.str;
        example = "192.0.2.10";
        description = "Local IPv4 address the receiver listens on.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 19532;
        description = "TCP port the receiver listens on.";
      };

      allowedSources = lib.mkOption {
        type = lib.types.nonEmptyListOf lib.types.str;
        example = ["192.0.2.20"];
        description = "IPv4 addresses allowed to connect to the receiver.";
      };

      maxUse = lib.mkOption {
        type = lib.types.str;
        default = "1G";
        description = "Disk space the received journals may use in total.";
      };

      readers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["alice"];
        description = ''
          Users who may read the received journals without root. They join the
          receiver's group. The receiver writes its journal files with mode
          0640 into /var/log/journal/remote (mode 0755), so the group can read
          them but not change, add or delete them.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.sender.enable {
      environment.etc."systemd/journald@${namespace}.conf".text = ''
        [Journal]
        Storage=persistent
        SystemMaxUse=${cfg.sender.localMaxUse}
      '';

      systemd.services.pressure-recorder = {
        description = "Sample pressure stall information and disk statistics";
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          ExecStart = "${lib.getExe sampler} ${toString cfg.sender.interval}";
          LogNamespace = namespace;
          SyslogIdentifier = "pressure-recorder";
          Restart = "always";
          RestartSec = "5s";
          # Keep sampling while the host is short of memory.
          OOMScoreAdjust = -900;
          MemoryMax = "32M";

          DynamicUser = true;
          CapabilityBoundingSet = "";
          NoNewPrivileges = true;
          PrivateDevices = true;
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
          ProtectProc = "invisible";
          RestrictAddressFamilies = "AF_UNIX";
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = ["@system-service" "~@privileged @resources"];
          UMask = "0077";
        };
      };

      services.journald.upload = {
        enable = true;
        settings.Upload.URL = cfg.sender.url;
      };

      # Ship only the sampler's namespace, not the host's whole journal.
      systemd.services.systemd-journal-upload = {
        wants = ["pressure-recorder.service"];
        after = ["pressure-recorder.service"];
        serviceConfig.ExecStart = [
          ""
          "${config.systemd.package}/lib/systemd/systemd-journal-upload --save-state --namespace=${namespace}"
        ];
      };
    })

    (lib.mkIf cfg.receiver.enable {
      services.journald.remote = {
        enable = true;
        inherit (cfg.receiver) port;
        settings.Remote = {
          SplitMode = "host";
          MaxUse = cfg.receiver.maxUse;
          MaxFileSize = "64M";
        };
      };

      # The receiver's static user would otherwise add its default shell
      # package to system-path again, which changes polkit's restart trigger
      # and dbus's reload trigger. The same nologin as a path leaves
      # system-path unchanged.
      users.users.systemd-journal-remote.shell = "${pkgs.shadow}/bin/nologin";

      users.groups.systemd-journal-remote.members = cfg.receiver.readers;

      systemd.sockets.systemd-journal-remote = {
        listenStreams = lib.mkForce [
          ""
          "${cfg.receiver.listenAddress}:${receiverPort}"
        ];
        socketConfig = {
          # Bind before the address is configured at boot.
          FreeBind = true;
          IPAddressAllow = cfg.receiver.allowedSources;
          IPAddressDeny = "any";
        };
      };

      networking.firewall.extraCommands = lib.mkIf (!config.networking.nftables.enable) (
        lib.concatMapStrings (source: ''
          iptables -A nixos-fw -p tcp -s ${source} -d ${cfg.receiver.listenAddress} --dport ${receiverPort} -j nixos-fw-accept
        '')
        cfg.receiver.allowedSources
      );

      networking.firewall.extraInputRules = lib.mkIf config.networking.nftables.enable ''
        ip saddr { ${lib.concatStringsSep ", " cfg.receiver.allowedSources} } ip daddr ${cfg.receiver.listenAddress} tcp dport ${receiverPort} accept
      '';
    })
  ];
}
