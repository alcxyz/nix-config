# Declarative UMU launchers for Windows applications outside Steam.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.umuApps;

  windowMatcherType = lib.types.submodule {
    options = {
      classRegex = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Regular expression matching the managed window class.";
      };

      titleRegex = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = ".*";
        description = "Regular expression matching the managed window title.";
      };
    };
  };

  appType = lib.types.submodule ({name, ...}: {
    options = {
      displayName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = name;
        description = "Name shown by the generated desktop entry.";
      };

      comment = lib.mkOption {
        type = lib.types.str;
        default = "Windows application launched directly through UMU";
        description = "Comment shown by the generated desktop entry.";
      };

      icon = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "applications-games";
        description = "Icon name or path used by the generated desktop entry.";
      };

      prefix = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Existing Proton compatibility-data directory used by the application.";
      };

      executable = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Absolute path to the Windows executable.";
      };

      arguments = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Arguments passed to the Windows executable.";
      };

      protonPackage = lib.mkOption {
        type = lib.types.package;
        description = "Proton compatibility-tool tree containing the proton executable.";
      };

      gameId = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "umu-default";
        description = "UMU game identifier. Use umu-default to avoid application-specific protonfixes.";
      };

      store = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "UMU store identifier.";
      };

      role = lib.mkOption {
        type = lib.types.enum [
          "primary"
          "companion"
        ];
        default = "primary";
        description = ''
          Primary applications own the prefix lifecycle and refuse to start
          when that prefix is already active. Companion applications use
          Proton's same-prefix execution verb.
        '';
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Additional environment shared by applications using this prefix.";
      };

      useGameMode = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Run UMU through GameMode.";
      };

      desktopEntry = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to create an application-menu entry.";
      };

      staleRecoveryWindowMatchers = lib.mkOption {
        type = lib.types.listOf windowMatcherType;
        default = [];
        description = ''
          Hyprland window matchers used by a primary application's explicit
          launcher request. When its service has been active beyond the grace
          period but none of these windows remain, restart the stale service.
          An active same-prefix companion always blocks recovery.
        '';
      };

      staleRecoveryGraceSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Minimum primary-service age before missing-window recovery is allowed.";
      };
    };
  });

  reservedEnvironment = [
    "GAMEID"
    "PROTONPATH"
    "PROTON_VERB"
    "STEAM_COMPAT_DATA_PATH"
    "STORE"
    "WINEPREFIX"
  ];

  prefixContracts = lib.groupBy (app: app.prefix) (lib.attrValues cfg.apps);
  matchingPrefixContracts = lib.all (
    apps: let
      first = lib.head apps;
    in
      lib.all (
        app:
          toString app.protonPackage
          == toString first.protonPackage
          && app.gameId == first.gameId
          && app.store == first.store
          && app.environment == first.environment
      )
      apps
  ) (lib.attrValues prefixContracts);

  mkApplication = name: app:
    import ./application.nix {
      inherit app cfg lib name pkgs;
    };

  applications = lib.mapAttrs mkApplication cfg.apps;
in {
  options.programs.umuApps = {
    enable = lib.mkEnableOption "declarative Windows application launchers through UMU";

    package = lib.mkPackageOption pkgs "umu-launcher" {};

    apps = lib.mkOption {
      type = lib.types.attrsOf appType;
      default = {};
      description = "Windows applications exposed through UMU launchers.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isLinux;
        message = "programs.umuApps is supported only on Linux";
      }
      {
        assertion = lib.all (name: builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" name != null) (lib.attrNames cfg.apps);
        message = "programs.umuApps application names must be safe systemd unit identifiers";
      }
      {
        assertion = lib.all (
          app: lib.intersectLists reservedEnvironment (lib.attrNames app.environment) == []
        ) (lib.attrValues cfg.apps);
        message = "programs.umuApps reserves UMU and Proton prefix environment variables";
      }
      {
        assertion = matchingPrefixContracts;
        message = "programs.umuApps entries sharing a prefix must use the same Proton and environment contract";
      }
      {
        assertion = lib.all (
          app: app.role == "primary" || app.staleRecoveryWindowMatchers == []
        ) (lib.attrValues cfg.apps);
        message = "programs.umuApps stale window recovery is supported only for primary applications";
      }
    ];

    home.packages = map (application: application.starter) (lib.attrValues applications);

    xdg.desktopEntries = lib.mapAttrs' (
      name: application:
        lib.nameValuePair "umu-${name}" {
          name = application.app.displayName;
          comment = application.app.comment;
          icon = application.app.icon;
          exec = lib.getExe application.starter;
          terminal = false;
          type = "Application";
          categories = ["Game"];
          startupNotify = false;
          settings.TryExec = lib.getExe application.starter;
        }
    ) (lib.filterAttrs (_: application: application.app.desktopEntry) applications);

    systemd.user.services =
      lib.mapAttrs' (
        _: application:
          lib.nameValuePair (lib.removeSuffix ".service" application.unitName) {
            Unit = {
              Description = "Direct UMU application: ${application.app.displayName}";

              # A Home Manager activation must never interrupt a running game.
              # Reload the new unit for its next launch, but keep the current
              # process tree alive when the generated runner changes.
              X-SwitchMethod = "keep-old";
            };
            Service = {
              Type = "exec";
              ExecStart = lib.getExe application.runner;
              KillMode = "mixed";
              TimeoutStopSec = 20;
            };
          }
      )
      applications;
  };
}
