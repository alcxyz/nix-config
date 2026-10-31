{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.isolated-agent;
  account = config.users.users.${cfg.user};
  sudoDenial = "${cfg.user} ALL=(ALL:ALL) !ALL\n";
  polkitDenial = ''
    polkit.addRule(function(action, subject) {
      if (subject.user === ${builtins.toJSON cfg.user}) {
        return polkit.Result.NO;
      }
    });
  '';
in {
  options.services.isolated-agent = {
    enable = lib.mkEnableOption "a separate unprivileged agent account and T3 server";
    user = lib.mkOption {
      type = lib.types.strMatching "[a-z][a-z0-9-]*";
      default = "isolated-agent";
    };
    package = lib.mkOption {
      type = lib.types.package;
      description = "Explicit T3 server package from the consumer's package set.";
    };
    providerPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = "Provider CLIs available in the separate account.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 3780;
    };
    start = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Start at boot only after the runtime profile is qualified.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = account.extraGroups == [];
        message = "The isolated agent must have no supplementary groups.";
      }
      {
        assertion =
          lib.all (group: !(builtins.elem cfg.user group.members))
          (builtins.attrValues (builtins.removeAttrs config.users.groups [cfg.user]));
        message = "Other groups must not list the isolated agent as a member.";
      }
      {
        assertion = lib.all (entry: !(builtins.elem entry [cfg.user "@${cfg.user}" "*"])) config.nix.settings.trusted-users;
        message = "The isolated agent must not be a trusted Nix daemon user.";
      }
      {
        assertion = lib.hasSuffix sudoDenial config.security.sudo.extraConfig;
        message = "The isolated agent sudo denial must end security.sudo.extraConfig.";
      }
      {
        assertion = lib.hasPrefix polkitDenial config.security.polkit.extraConfig;
        message = "The isolated agent Polkit denial must begin security.polkit.extraConfig.";
      }
      {
        assertion = !(config.security.sudo-rs.enable or false);
        message = "The isolated agent module qualifies classic sudo only, not sudo-rs.";
      }
    ];

    users.groups.${cfg.user} = {};
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      home = "/var/lib/${cfg.user}";
      createHome = true;
      homeMode = "0700";
      shell = pkgs.bashInteractive;
      packages = cfg.providerPackages;
    };

    # Order denials around extraConfig grants. Separately installed policy
    # files remain part of the consuming host's deployment qualification.
    security.sudo.extraConfig = lib.mkOrder 2000 sudoDenial;
    security.polkit.extraConfig = lib.mkOrder 0 polkitDenial;

    systemd.services.isolated-agent = {
      description = "Separate unprivileged T3 agent server";
      wantedBy = lib.optionals cfg.start ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      path = cfg.providerPackages ++ [pkgs.git pkgs.coreutils];
      environment = {
        HOME = account.home;
        XDG_CONFIG_HOME = "${account.home}/.config";
        XDG_STATE_HOME = "${account.home}/.local/state";
        XDG_CACHE_HOME = "${account.home}/.cache";
      };
      serviceConfig = {
        User = cfg.user;
        Group = cfg.user;
        WorkingDirectory = account.home;
        ExecStart = "${cfg.package}/bin/t3 serve --host 127.0.0.1 --port ${toString cfg.port} --base-dir ${account.home}/.t3";
        Restart = "on-failure";
        RestartSec = 15;
        SuccessExitStatus = 130;
        UMask = "0077";
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [account.home];
        InaccessiblePaths = ["-/run/secrets" "-/run/secrets-for-users" "-/run/user" "-/nix/var/nix/daemon-socket"];
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        RemoveIPC = true;
      };
    };
  };
}
