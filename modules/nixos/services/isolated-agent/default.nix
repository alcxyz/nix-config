{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  cfg = config.services.isolated-agent;
  account = config.users.users.${cfg.user};
  # Every isolated account: the T3 server's and the extra ones.
  accounts = lib.optional cfg.enable cfg.user ++ cfg.extraAccounts;
  sudoDenial = lib.concatMapStrings (user: "${user} ALL=(ALL:ALL) !ALL\n") accounts;
  polkitDenial = ''
    polkit.addRule(function(action, subject) {
      if (${builtins.toJSON accounts}.indexOf(subject.user) >= 0) {
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
    extraAccounts = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[a-z][a-z0-9-]*");
      default = [];
      description = ''
        Further separate accounts with the same isolation (no supplementary
        groups, sudo or Polkit grants, not trusted by the Nix daemon, a
        private home under /var/lib) and no T3 server. The consumer runs its
        own service as each account. They work without `enable`.
      '';
    };
  };

  config = lib.mkIf (accounts != []) (lib.mkMerge [
    {
      assertions =
        lib.concatMap (user: [
          {
            assertion = config.users.users.${user}.extraGroups == [];
            message = "The isolated agent account ${user} must have no supplementary groups.";
          }
          {
            assertion =
              lib.all (group: !(builtins.elem user group.members))
              (builtins.attrValues (builtins.removeAttrs config.users.groups [user]));
            message = "Other groups must not list the isolated agent account ${user} as a member.";
          }
          {
            # A name that matches a group another module defines (disk, kvm,
            # incus-admin, ...) would make that group, and whatever it grants,
            # the account's primary group, so only this module may define it.
            assertion =
              lib.length (lib.filter (definition: definition.value ? ${user}) options.users.groups.definitionsWithLocations)
              == 1
              && config.users.groups.${user}.members == []
              && lib.all (other: other.name == user || other.group != user) (builtins.attrValues config.users.users);
            message = "The isolated agent account ${user} must have a primary group of its own, not an existing one.";
          }
          {
            assertion = lib.all (entry: !(builtins.elem entry [user "@${user}" "*"])) config.nix.settings.trusted-users;
            message = "The isolated agent account ${user} must not be a trusted Nix daemon user.";
          }
        ])
        accounts
        ++ [
          {
            assertion = lib.allUnique accounts;
            message = "The isolated agent accounts must be listed once each.";
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

      users.groups = lib.genAttrs accounts (_: {});
      users.users = lib.genAttrs accounts (user: {
        isSystemUser = true;
        group = user;
        home = "/var/lib/${user}";
        createHome = true;
        homeMode = "0700";
        shell = pkgs.bashInteractive;
      });

      # Order denials around extraConfig grants. Separately installed policy
      # files remain part of the consuming host's deployment qualification.
      security.sudo.extraConfig = lib.mkOrder 2000 sudoDenial;
      security.polkit.extraConfig = lib.mkOrder 0 polkitDenial;
    }
    (lib.mkIf cfg.enable {
      users.users.${cfg.user}.packages = [cfg.package] ++ cfg.providerPackages;

      # Project context stays below its own directory, outside sibling runtime
      # and provider state. This is a workspace boundary, not a filesystem sandbox.
      systemd.tmpfiles.rules = ["d ${account.home}/workspace 0700 ${cfg.user} ${cfg.user} -"];

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
          T3CODE_AUTO_BOOTSTRAP_PROJECT_FROM_CWD = "false";
        };
        serviceConfig = {
          User = cfg.user;
          Group = cfg.user;
          WorkingDirectory = account.home;
          ExecStart = "${cfg.package}/bin/t3 start --mode desktop --no-browser --host 127.0.0.1 --port ${toString cfg.port} --base-dir ${account.home}/.t3";
          Restart = "on-failure";
          RestartSec = 15;
          SuccessExitStatus = 130;
          # Provider/server startup may contain pairing material. Keep it out of
          # the shared journal; unit state and exit status remain observable.
          StandardOutput = "null";
          StandardError = "null";
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
    })
  ]);
}
