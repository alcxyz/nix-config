{
  config,
  lib,
  pkgs,
  ...
}: let
  client = config.services.managed-ssh-forward;
  target = config.services.ssh-forward-target;
  knownHosts = pkgs.writeText "managed-ssh-forward-known-hosts" "${client.remoteHost} ${client.hostPublicKey}\n";
  keyOptions = ''restrict,port-forwarding,permitopen="127.0.0.1:${toString target.targetPort}",command="${pkgs.coreutils}/bin/false"'';
  word = lib.types.strMatching "[a-zA-Z0-9_.:-]+";
in {
  options.services.managed-ssh-forward = {
    enable = lib.mkEnableOption "a temporary boot-managed SSH forward PoC (remove once the NetBird link is live)";
    remoteHost = lib.mkOption {type = word;};
    remoteUser = lib.mkOption {type = word;};
    hostPublicKey = lib.mkOption {type = lib.types.str;};
    identityFile = lib.mkOption {
      type = lib.types.str;
      description = "Root-owned private key supplied only through systemd credentials.";
    };
    localPort = lib.mkOption {type = lib.types.port;};
    targetPort = lib.mkOption {type = lib.types.port;};
  };
  options.services.ssh-forward-target = {
    enable = lib.mkEnableOption "a public-key-only, single-destination SSH forwarding account";
    user = lib.mkOption {
      type = word;
      default = "ssh-forward-target";
    };
    publicKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
    };
    targetPort = lib.mkOption {type = lib.types.port;};
  };
  config = lib.mkMerge [
    (lib.mkIf client.enable {
      environment.etc."managed-ssh-forward/known_hosts".source = knownHosts;
      systemd.services.managed-ssh-forward = {
        description = "Temporary SSH forward PoC (remove once the NetBird link is live)";
        wantedBy = ["multi-user.target"];
        after = ["network-online.target"];
        wants = ["network-online.target"];
        unitConfig.StartLimitIntervalSec = 0;
        serviceConfig = {
          Type = "exec";
          DynamicUser = true;
          LoadCredential = ["identity:${client.identityFile}"];
          ExecStart = lib.escapeShellArgs [
            "${pkgs.openssh}/bin/ssh"
            "-F"
            "/dev/null"
            "-N"
            "-n"
            "-T"
            "-o"
            "BatchMode=yes"
            "-o"
            "IdentitiesOnly=yes"
            "-o"
            "IdentityAgent=none"
            "-o"
            "ExitOnForwardFailure=yes"
            "-o"
            "ServerAliveInterval=15"
            "-o"
            "ServerAliveCountMax=3"
            "-o"
            "ConnectTimeout=10"
            "-o"
            "ConnectionAttempts=1"
            "-o"
            "StrictHostKeyChecking=yes"
            "-o"
            "UserKnownHostsFile=/etc/managed-ssh-forward/known_hosts"
            "-o"
            "GlobalKnownHostsFile=/dev/null"
            "-o"
            "LogLevel=ERROR"
            "-i"
            "%d/identity"
            "-L"
            "127.0.0.1:${toString client.localPort}:127.0.0.1:${toString client.targetPort}"
            "${client.remoteUser}@${client.remoteHost}"
          ];
          Restart = "always";
          RestartSec = 5;
          NoNewPrivileges = true;
          CapabilityBoundingSet = "";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
          UMask = "0077";
        };
      };
    })
    (lib.mkIf target.enable {
      services.openssh.enable = true;
      users.groups.${target.user} = {};
      users.users.${target.user} = {
        isSystemUser = true;
        group = target.user;
        home = "/var/empty";
        shell = "${pkgs.shadow}/bin/nologin";
        openssh.authorizedKeys.keys = map (key: "${keyOptions} ${key}") target.publicKeys;
      };
      services.openssh.extraConfig = ''
        Match User ${target.user}
          AuthenticationMethods publickey
          PasswordAuthentication no
          KbdInteractiveAuthentication no
          AllowTcpForwarding local
          PermitOpen 127.0.0.1:${toString target.targetPort}
          PermitListen none
          AllowStreamLocalForwarding no
          AllowAgentForwarding no
          X11Forwarding no
          PermitTTY no
          PermitUserRC no
          MaxSessions 0
          ForceCommand ${pkgs.coreutils}/bin/false
        Match all
      '';
    })
  ];
}
