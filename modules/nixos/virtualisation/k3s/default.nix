# modules/nixos/virtualisation/k3s/default.nix
{
  config,
  pkgs,
  lib,
  hostK8sRole ? null,
  inventory ? null,
  ...
}:
with lib; let
  # Define options specifically for K3s
  cfg = config.k3s; # Using a top-level 'k3s' option for clarity
  k3sPackage =
    if cfg.nodeIp != null
    then pkgs.k3s-flannel-node-source
    else pkgs.k3s;
  roleDefault =
    if hostK8sRole == null
    then "server"
    else hostK8sRole.role;
  roleMaxPods =
    if hostK8sRole == null
    then 110
    else hostK8sRole.maxPods or 110;
  inventoryExtraFlags =
    if hostK8sRole == null
    then []
    else hostK8sRole.extraFlags or [];
  firewallDropGuard = config.networking.firewall.enable && !config.networking.nftables.enable;
  peerIsIPv6 = peer: lib.hasInfix ":" peer;
  peerIsAddress = peer:
    builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" peer
    != null
    || (peerIsIPv6 peer && builtins.match "[0-9a-fA-F:]+" peer != null);
  selfFenceStatus = pkgs.writeShellApplication {
    name = "node-self-fence-status";
    runtimeInputs = [pkgs.systemd];
    text = ''
      export NODE_NAME=${escapeShellArg config.networking.hostName}
      export PEERS=${escapeShellArg (concatStringsSep " " cfg.selfFence.peers)}
      export STATE_PORT=${toString cfg.selfFence.statePort}
      export STATE_KEY_FILE=${escapeShellArg (toString cfg.selfFence.keyFile)}
      exec ${pkgs.python3}/bin/python3 ${./self-fence.py} --status "$@"
    '';
  };
  # Other k3s servers from the inventory, addressed by their LAN address.
  inventoryServerPeers =
    if inventory == null
    then []
    else
      mapAttrsToList (name: host: host.sshHostname or name) (filterAttrs (
          name: host: let
            role = host.k8sRole or null;
          in
            name != config.networking.hostName && role != null && inventory.k8sRoles.${role}.role == "server"
        )
        inventory.hosts);
  # Node-to-node ports the cluster needs whenever the host firewall is on.
  clusterTCPPorts = [
    6443 # K3s API Server
    2379 # K3s etcd client port
    2380 # K3s etcd peer port
    7946 # MetalLB speaker memberlist
    10250 # Kubelet metrics endpoint for Metrics Server
  ];
  clusterUDPPorts = [
    8472 # Flannel VXLAN backend
    7946 # MetalLB speaker memberlist
  ];
  # Pod and service traffic traverses the node over the CNI bridge and
  # flannel overlay. Treat those interfaces as trusted so cross-node
  # cluster traffic is not filtered like regular host ingress.
  clusterInterfaces = [
    "cni0"
    "flannel.1"
  ];
  missingFrom = required: present: lib.filter (item: !(builtins.elem item present)) required;
  firewall = config.networking.firewall;
  missingClusterAccess =
    map toString (missingFrom clusterTCPPorts firewall.allowedTCPPorts)
    ++ map (port: "${toString port}/udp") (missingFrom clusterUDPPorts firewall.allowedUDPPorts)
    ++ missingFrom clusterInterfaces firewall.trustedInterfaces;
  networkPathAudit = pkgs.writeShellApplication {
    name = "k8s-node-network-audit";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.iproute2
      k3sPackage
    ];
    text = builtins.readFile pkgs.k8s-node-reboot.networkAuditScript;
  };
in {
  # Define the NixOS options for this module
  options.k3s = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable K3s server setup.";
    };

    role = mkOption {
      type = types.enum [
        "server"
        "agent"
      ];
      default = roleDefault;
      description = "The role of this node in the K3s cluster.";
    };

    extraFlags = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra flags to pass to the K3s server/agent binary.";
    };

    maxPods = mkOption {
      type = types.ints.positive;
      default = roleMaxPods;
      description = "Maximum number of Pods the kubelet may schedule on this node.";
    };

    nodeIp = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Stable node address advertised by K3s and used as the Flannel VXLAN endpoint.";
    };

    nodeInterface = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Physical LAN interface required for Flannel and Kubernetes node peer routes.";
    };

    disallowedNodeInterfaces = mkOption {
      type = types.listOf types.str;
      default = ["wt0"];
      description = "Interfaces that must never carry Kubernetes node or Flannel underlay traffic.";
    };

    tlsSans = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Additional Subject Alternative Names for the k3s API server certificate.";
    };

    serverAddr = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Server URL to join for non-bootstrap server/agent nodes.";
    };

    tokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to a file containing the shared k3s server token.";
    };

    clusterInit = mkOption {
      type = types.bool;
      default = false;
      description = "Initialize or migrate the cluster to embedded etcd on this server.";
    };

    rebootWatchdogSec = mkOption {
      type = types.str;
      default = "3min";
      description = ''
        systemd reboot watchdog timeout. Set to "0" on hosts whose firmware
        reset path has not been qualified or is known to wedge during reboot.
      '';
    };

    selfFence = {
      enable = mkOption {
        type = types.bool;
        default = cfg.role == "server";
        description = ''
          Reboot this server when it cannot confirm it is a healthy cluster
          member, so its volumes can be released safely (gitops ADR-058,
          ADR-0082). Keep k3s from starting until the cluster has released it
          or verified fenced peers rule out a quorum, including peers that
          jointly released within 60 seconds and named this node.
        '';
      };

      mode = mkOption {
        type = types.enum [
          "observe"
          "enforce"
        ];
        default = "enforce";
        description = "observe only logs fencing decisions; enforce acts on them.";
      };

      peers = mkOption {
        type = types.listOf types.str;
        default = inventoryServerPeers;
        description = ''
          IPv4 or IPv6 addresses of every other k3s server. Complete membership
          is required for the fence-release quorum proof. These addresses also
          scope state endpoint firewall access and source filtering in the agent.
        '';
      };

      statePort = mkOption {
        type = types.port;
        default = 9097;
        description = ''
          TCP port for authenticated peer fence state, independent of k3s.
          The host firewall allows this port from configured peer addresses;
          the agent also filters sources to peers and loopback, including
          traffic on trusted interfaces. Failed binds retry every 30 seconds.
          Signed state includes the last release rule and counted peer names.
        '';
      };

      keyFile = mkOption {
        type = types.nullOr types.path;
        default = cfg.tokenFile;
        defaultText = literalExpression "config.k3s.tokenFile";
        description = ''
          Runtime file containing shared key material for peer authentication.
          The agent and node-self-fence-status read this path as root and
          derive a protocol-specific key from it on every request and probe, so
          rotation or a file appearing after startup needs no agent restart.
          Every server must use matching key material. Never put its contents
          in the Nix store.
        '';
      };

      fenceAfterSeconds = mkOption {
        type = types.ints.positive;
        default = 60;
        description = ''
          How long the node must be unhealthy before it fences (150 s when the
          control plane looks down everywhere). The cluster-side out-of-service
          taint must wait longer than the worst case documented in
          self-fence.py: boot grace 150 s + ambiguous deadline 150 s + polls
          ~24 s + a reboot attempt and retry ~65 s + systemd-shutdown killing
          and unmounting up to ~90 s, about 480 s from failure to a fenced
          node. With rebootWatchdogSec = "0" the reboot may wedge after
          processes are gone: the node stays fenced but needs a power cycle.
          Any API release evidence wins over other API answers; otherwise an
          API answer holds the fence. With no API answers, verified fenced
          peers or recent joint releases must rule out a quorum.
          Fence release requires stable positive peer evidence followed by a
          final check, rather than a fixed elapsed-time fallback (ADR-0082).
        '';
      };
    };
  };

  # Apply configuration if k3s.enable is true
  config = mkIf cfg.enable {
    assertions =
      optional (hostK8sRole != null) {
        assertion = cfg.role == hostK8sRole.role;
        message = "k3s.role for ${config.networking.hostName} must match inventory k8sRole (${hostK8sRole.role}).";
      }
      ++ optional (cfg.nodeIp != null) {
        assertion = cfg.nodeInterface != null;
        message = "k3s.nodeInterface must be set when k3s.nodeIp is pinned.";
      }
      ++ optional cfg.selfFence.enable {
        assertion = cfg.role == "server" && cfg.selfFence.peers != [];
        message = "k3s.selfFence on ${config.networking.hostName} needs a server role and at least one peer.";
      }
      ++ optionals cfg.selfFence.enable [
        {
          assertion = cfg.selfFence.keyFile != null;
          message = "k3s.selfFence.keyFile must be set when self-fencing is enabled.";
        }
        {
          assertion = all peerIsAddress cfg.selfFence.peers;
          message = "k3s.selfFence.peers must contain IPv4 or IPv6 addresses for source-scoped firewall rules.";
        }
      ]
      # A firewall that blocks cluster traffic isolates the node while it keeps
      # internet access, which leaves its cloudflared connector serving errors.
      # This checks declared openings only (exact entries, not port ranges);
      # k3s-firewall-drop-guard handles the runtime reload drop rule.
      ++ optional firewall.enable {
        assertion = missingClusterAccess == [];
        message = "k3s on ${config.networking.hostName} needs cluster traffic allowed through the firewall; missing: ${lib.concatStringsSep ", " missingClusterAccess}.";
      };

    # Ensure rpcbind is enabled, often a dependency for Kubernetes components
    services.rpcbind.enable = true;

    # Bound the final reboot phase if firmware or a kernel driver wedges after
    # userspace has shut down. Runtime watchdog policy remains host-specific.
    systemd.settings.Manager.RebootWatchdogSec = cfg.rebootWatchdogSec;

    # ADR-058: fence a server that cannot confirm it is a healthy cluster
    # member. It runs outside k3s so it still works when k3s is the problem.
    systemd.services.node-self-fence = mkIf cfg.selfFence.enable {
      description = "Fence this k3s server when it is cut off from the cluster";
      # No ordering on k3s: a k3s start job stuck in activating must not keep
      # the agent from starting.
      wantedBy = ["multi-user.target"];
      path = [
        k3sPackage
        pkgs.systemd
      ];
      environment = {
        NODE_NAME = config.networking.hostName;
        PEERS = concatStringsSep " " cfg.selfFence.peers;
        FENCE_MODE = cfg.selfFence.mode;
        FENCE_AFTER = toString cfg.selfFence.fenceAfterSeconds;
        STATE_PORT = toString cfg.selfFence.statePort;
        STATE_KEY_FILE = toString cfg.selfFence.keyFile;
        K3S_BIN = "${k3sPackage}/bin/k3s";
        # Persistent, so the fence survives the reboot that enforces it.
        FENCE_MARKER = "/var/lib/node-self-fence/fenced";
      };
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "main";
        ExecStart = "${pkgs.python3}/bin/python3 ${./self-fence.py}";
        Restart = "always";
        RestartSec = 5;
        # The agent also feeds the watchdog while fencing commands run.
        WatchdogSec = 120;
        StateDirectory = "node-self-fence";
        # History times are CLOCK_BOOTTIME: keep them across agent restarts,
        # never across a reboot.
        RuntimeDirectory = "node-self-fence";
        RuntimeDirectoryPreserve = "yes";
      };
    };

    # While a fence is in place, nothing (timers, rebuilds, operators) may start
    # k3s and its old containers' volumes; the agent removes the marker first.
    systemd.services.k3s.unitConfig.ConditionPathExists =
      mkIf cfg.selfFence.enable "!/var/lib/node-self-fence/fenced";

    # A newly installed host may start with a reset RTC.  time-sync.target is
    # only an ordering target and does not itself prove that NTP has corrected
    # the clock.  Starting k3s before that correction can mint an immediately
    # expired local CA, preventing a clean server from joining the cluster.
    systemd.services.k3s-clock-sanity = {
      description = "Wait for a sane synchronized clock before starting k3s";
      wants = [
        "network-online.target"
        "systemd-timesyncd.service"
      ];
      after = [
        "network-online.target"
        "systemd-timesyncd.service"
      ];
      before = ["k3s.service"];
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail
        minimum_epoch=1767225600 # 2026-01-01T00:00:00Z
        for _ in $(${pkgs.coreutils}/bin/seq 1 180); do
          now=$(${pkgs.coreutils}/bin/date +%s)
          if [[ -e /run/systemd/timesync/synchronized && $now -ge $minimum_epoch ]]; then
            exit 0
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done
        echo "clock did not become synchronized and sane before k3s startup" >&2
        exit 1
      '';
    };

    systemd.services.k3s = {
      requires = ["k3s-clock-sanity.service"];
      after = ["k3s-clock-sanity.service"];
    };

    # Configure K3s service
    services.k3s =
      {
        package = k3sPackage;
        enable = true;
        role = cfg.role;
        extraFlags =
          inventoryExtraFlags
          ++ optional (cfg.nodeIp != null) "--node-ip=${cfg.nodeIp}"
          ++ optional (cfg.nodeInterface != null) "--flannel-iface=${cfg.nodeInterface}"
          ++ optional (cfg.maxPods != 110) "--kubelet-arg=max-pods=${toString cfg.maxPods}"
          ++ concatMap (san: [
            "--tls-san"
            san
          ])
          cfg.tlsSans
          ++ cfg.extraFlags;
      }
      // optionalAttrs (cfg.serverAddr != null) {
        serverAddr = cfg.serverAddr;
      }
      // optionalAttrs (cfg.tokenFile != null) {
        tokenFile = cfg.tokenFile;
      }
      // optionalAttrs cfg.clusterInit {
        clusterInit = true;
      };

    systemd.services.k3s-network-path-audit = mkIf (cfg.nodeIp != null && cfg.nodeInterface != null) {
      description = "Fail-closed audit of the Kubernetes LAN underlay";
      after = [
        "k3s.service"
        "network-online.target"
      ];
      wants = [
        "k3s.service"
        "network-online.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = concatStringsSep " " (
          [
            "${networkPathAudit}/bin/k8s-node-network-audit"
            "--node"
            (escapeShellArg config.networking.hostName)
            "--expected-node-ip"
            (escapeShellArg cfg.nodeIp)
            "--expected-interface"
            (escapeShellArg cfg.nodeInterface)
          ]
          ++ concatMap (interface: [
            "--disallowed-interface"
            (escapeShellArg interface)
          ])
          cfg.disallowedNodeInterfaces
        );
      };
    };

    systemd.timers.k3s-network-path-audit = mkIf (cfg.nodeIp != null && cfg.nodeInterface != null) {
      description = "Continuously verify the Kubernetes LAN underlay";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "5m";
        AccuracySec = "30s";
        Persistent = true;
        Unit = "k3s-network-path-audit.service";
      };
    };

    # A NixOS firewall reload appends a temporary drop-all `nixos-drop` jump to
    # INPUT and removes it when the reload finishes. k3s's network-policy
    # controller rewrites the filter table from an earlier snapshot, so a
    # reload that overlaps its sync can resurrect that jump and leave the node
    # dropping all ingress (2026-10-01, nux). Remove any jump that remains
    # while no reload is running.
    systemd.services.k3s-firewall-drop-guard = mkIf firewallDropGuard {
      description = "Remove a stale firewall reload drop rule on k3s nodes";
      serviceConfig = {
        Type = "oneshot";
        LogLevelMax = "notice";
      };
      path = [config.networking.firewall.package pkgs.systemd];
      script = ''
        reloading() {
          [[ "$(systemctl show -p ActiveState --value firewall.service)" == reloading ]]
        }
        reloading && exit 0
        for cmd in iptables ip6tables; do
          $cmd -w 5 -C INPUT -j nixos-drop 2>/dev/null || continue
          reloading && exit 0
          while $cmd -w 5 -D INPUT -j nixos-drop 2>/dev/null; do :; done
          echo "<4>removed stale nixos-drop jump from $cmd INPUT"
        done
      '';
    };

    systemd.timers.k3s-firewall-drop-guard = mkIf firewallDropGuard {
      description = "Check for a stale firewall reload drop rule";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "1m";
        OnUnitActiveSec = "20s";
        AccuracySec = "1s";
      };
    };

    # Configure firewall for K3s
    networking.firewall.allowedTCPPorts = clusterTCPPorts;
    networking.firewall.allowedUDPPorts = clusterUDPPorts;
    networking.firewall.trustedInterfaces = clusterInterfaces;

    # Use the backend's input allowance hook. NixOS recreates nixos-fw on
    # reload, so these iptables rules need no separate stop-time cleanup.
    networking.firewall.extraCommands = mkIf (cfg.selfFence.enable && firewallDropGuard) (
      concatMapStringsSep "\n" (peer: ''
        ${
          if peerIsIPv6 peer
          then "ip6tables"
          else "iptables"
        } -w -A nixos-fw -p tcp -s ${escapeShellArg peer} --dport ${toString cfg.selfFence.statePort} -j nixos-fw-accept
      '')
      cfg.selfFence.peers
    );
    networking.firewall.extraInputRules = mkIf (cfg.selfFence.enable && firewall.enable && config.networking.nftables.enable) (
      concatMapStringsSep "\n" (peer: ''
        ${
          if peerIsIPv6 peer
          then "ip6"
          else "ip"
        } saddr ${peer} tcp dport ${toString cfg.selfFence.statePort} accept
      '')
      cfg.selfFence.peers
    );

    # Ensure the k3s package is available in the system environment
    environment.systemPackages = [k3sPackage] ++ optional cfg.selfFence.enable selfFenceStatus;
  };
}
