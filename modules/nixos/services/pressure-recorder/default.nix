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
#
# Kernel console (optional, `sender.netconsole` and `receiver.netconsole`):
# the journal stops with the host, so a kernel lockup, stall, oops or panic
# never reaches the record above. netconsole sends the kernel's console
# output as UDP from the kernel itself, which keeps working while user space
# is stuck and, during a panic, until the reboot.
#
# Sender: the `netconsole` module loads at boot without a target, and
# `netconsole-target.service` creates a dynamic target through configfs once
# the interface holds `localAddress` and the receiver's MAC address is known
# (from the neighbour table, so the repository holds no MAC address). It
# checks every 30 seconds and repairs a target the kernel disabled or whose
# settings or receiver MAC address changed. Stopping the service leaves the
# target in place, so a hang late in shutdown (unmounts, driver unloads) still
# reaches the receiver; it disappears at reboot. Disabling the option leaves
# a running target until the next reboot.
#
# The console log level is raised to 7, so informational messages reach the
# console: at the default 4, the backtraces of soft and hard lockups and RCU stalls (KERN_DEFAULT) and the
# task stacks of hung-task and RCU stall reports (KERN_INFO) are filtered,
# leaving only their headlines. Oops and panic raise the level themselves.
#
# Receiver: one socket-activated `netconsole-<name>.service` per source
# listens on `listenAddress:<port>` for UDP from that source's IP address
# only (socket IP filter and firewall rule). The filter checks the source IP,
# so any process on the source host, and any container whose traffic it
# masquerades, can add lines; a leading `<N>` is kept as text and never sets
# the journal priority. The service writes each line to the system journal
# under the identifier `netconsole-<name>`, without rate limiting:
#   journalctl -t netconsole-xev --since -1h
#   journalctl -t netconsole-xev -n 200
# Lines carry the sender's kernel timestamp (seconds since its boot); a
# `netconsole-target:` line marks the sender resolving the receiver.
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

  netconsoleTarget = pkgs.writeShellApplication {
    name = "netconsole-target";
    runtimeInputs = [pkgs.coreutils pkgs.iproute2];
    text = builtins.readFile ./netconsole-target.sh;
  };

  netconsoleSources = cfg.receiver.netconsole.sources;

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

      netconsole = {
        enable = lib.mkEnableOption "sending the kernel console to the receiver host with netconsole";

        interface = lib.mkOption {
          type = lib.types.str;
          example = "eth0";
          description = "Network interface netconsole sends from.";
        };

        localAddress = lib.mkOption {
          type = lib.types.str;
          example = "192.0.2.20";
          description = "IPv4 address of `interface` the messages come from.";
        };

        remoteAddress = lib.mkOption {
          type = lib.types.str;
          example = "192.0.2.10";
          description = ''
            IPv4 address of the receiver, on the same link: netconsole sends
            to its MAC address and does not route.
          '';
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 6666;
          description = "UDP port of the receiver.";
        };
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

      netconsole.sources = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            address = lib.mkOption {
              type = lib.types.str;
              example = "192.0.2.20";
              description = "IPv4 address the source sends from.";
            };
            port = lib.mkOption {
              type = lib.types.port;
              default = 6666;
              description = "UDP port on `listenAddress` this source sends to.";
            };
          };
        });
        default = {};
        example = {xev.address = "192.0.2.20";};
        description = ''
          Hosts whose netconsole output to receive, by name. Each line goes to
          the system journal with the identifier `netconsole-<name>`.
        '';
      };
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.sender.netconsole.enable -> cfg.sender.enable;
          message = "services.pressure-recorder.sender.netconsole needs services.pressure-recorder.sender.enable.";
        }
        {
          assertion = netconsoleSources != {} -> cfg.receiver.enable;
          message = "services.pressure-recorder.receiver.netconsole.sources needs services.pressure-recorder.receiver.enable.";
        }
        {
          assertion = let
            ports = lib.mapAttrsToList (_: source: source.port) netconsoleSources;
          in
            lib.length ports == lib.length (lib.unique ports);
          message = "services.pressure-recorder.receiver.netconsole.sources need distinct ports.";
        }
      ];
    }

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

    (lib.mkIf (cfg.sender.enable && cfg.sender.netconsole.enable) {
      boot.kernelModules = ["netconsole"];
      # Let informational messages reach the consoles; see the header.
      boot.consoleLogLevel = 7;

      systemd.services.netconsole-target = {
        description = "Keep the netconsole target to ${cfg.sender.netconsole.remoteAddress} configured";
        wantedBy = ["multi-user.target"];
        wants = ["network-online.target"];
        after = ["network-online.target" "systemd-modules-load.service" "sys-kernel-config.mount"];
        requires = ["sys-kernel-config.mount"];
        # No stop action: the target outlives the service, so a hang late in
        # shutdown still reaches the receiver and a crash of the loop leaves
        # a working target alone.
        serviceConfig = {
          ExecStart = lib.escapeShellArgs [
            (lib.getExe netconsoleTarget)
            "receiver"
            cfg.sender.netconsole.interface
            cfg.sender.netconsole.localAddress
            cfg.sender.netconsole.remoteAddress
            (toString cfg.sender.netconsole.port)
            "30"
          ];
          Restart = "always";
          RestartSec = "30s";
          OOMScoreAdjust = -900;
          MemoryMax = "32M";

          # Root only to write the root-owned configfs files; no capabilities.
          CapabilityBoundingSet = "";
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ReadWritePaths = ["/sys/kernel/config/netconsole"];
          ProtectProc = "invisible";
          RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_NETLINK"];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = ["@system-service" "~@privileged @resources"];
          UMask = "0077";
        };
        startLimitIntervalSec = 0;
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

    (lib.mkIf (cfg.receiver.enable && netconsoleSources != {}) {
      systemd.sockets = lib.mapAttrs' (name: source:
        lib.nameValuePair "netconsole-${name}" {
          description = "Receive the kernel console of ${name}";
          wantedBy = ["sockets.target"];
          listenDatagrams = ["${cfg.receiver.listenAddress}:${toString source.port}"];
          socketConfig = {
            # Bind before the address is configured at boot.
            FreeBind = true;
            IPAddressAllow = source.address;
            IPAddressDeny = "any";
          };
        })
      netconsoleSources;

      # Every datagram is one or more console lines; cat copies them from
      # the socket on stdin to the journal stream on stdout, which splits
      # them into entries at newlines.
      systemd.services = lib.mapAttrs' (name: _:
        lib.nameValuePair "netconsole-${name}" {
          description = "Write the kernel console of ${name} to the journal";
          serviceConfig = {
            ExecStart = "${pkgs.coreutils}/bin/cat";
            StandardInput = "socket";
            StandardOutput = "journal";
            SyslogIdentifier = "netconsole-${name}";
            # Log every line at the default priority: a `<N>` prefix from
            # anything behind the source IP must not log at emerg or reach
            # journald's wall forwarding.
            SyslogLevelPrefix = false;
            # A panic sends its whole report at once.
            LogRateLimitIntervalSec = 0;
            Restart = "always";
            RestartSec = "5s";

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
            MemoryMax = "32M";
            SystemCallArchitectures = "native";
            SystemCallFilter = ["@system-service" "~@privileged @resources"];
            UMask = "0077";
          };
        })
      netconsoleSources;

      networking.firewall.extraCommands = lib.mkIf (!config.networking.nftables.enable) (
        lib.concatStrings (lib.mapAttrsToList (_: source: ''
            iptables -A nixos-fw -p udp -s ${source.address} -d ${cfg.receiver.listenAddress} --dport ${toString source.port} -j nixos-fw-accept
          '')
          netconsoleSources)
      );

      networking.firewall.extraInputRules = lib.mkIf config.networking.nftables.enable (
        lib.concatStrings (lib.mapAttrsToList (_: source: ''
            ip saddr ${source.address} ip daddr ${cfg.receiver.listenAddress} udp dport ${toString source.port} accept
          '')
          netconsoleSources)
      );
    })
  ];
}
