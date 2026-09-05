# Declarative UMU launchers for Windows applications outside Steam.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.umuApps;

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

  mkApplication = name: app: let
    unitName = "umu-app-${name}.service";
    prefixLock = builtins.substring 0 20 (builtins.hashString "sha256" app.prefix);
    environmentExports = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        variable: value: "export ${variable}=${lib.escapeShellArg value}"
      )
      app.environment
    );
    runCommand =
      if app.useGameMode
      then "${lib.getExe pkgs.gamemode} ${lib.getExe cfg.package}"
      else lib.getExe cfg.package;

    runner = pkgs.writeShellApplication {
      name = "umu-app-${name}-run";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.util-linux
      ];
      text = ''
        prefix=${lib.escapeShellArg app.prefix}
        executable=${lib.escapeShellArg app.executable}
        lock_file="''${XDG_RUNTIME_DIR:?}/umu-prefix-${prefixLock}.lock"

        prefix_in_use() {
          local environment pid
          for environment in /proc/[0-9]*/environ; do
            [ -r "$environment" ] || continue
            pid="''${environment#/proc/}"
            pid="''${pid%/environ}"
            [ "$pid" != "$$" ] || continue

            if tr '\0' '\n' 2>/dev/null <"$environment" \
              | grep -Fqx -e "STEAM_COMPAT_DATA_PATH=$prefix" \
                  -e "WINEPREFIX=$prefix" -e "WINEPREFIX=$prefix/pfx"; then
              return 0
            fi
          done
          return 1
        }

        [ -d "$prefix/pfx" ] || {
          echo "UMU prefix is unavailable: $prefix" >&2
          exit 66
        }
        [ -f "$executable" ] || {
          echo "Windows executable is unavailable: $executable" >&2
          exit 66
        }
        [ -x ${lib.escapeShellArg "${app.protonPackage}/proton"} ] || {
          echo "Pinned Proton runner is unavailable" >&2
          exit 66
        }

        # Serialize startup decisions without holding the lock for the whole
        # application lifetime; companions must remain able to join a prefix.
        exec 9>"$lock_file"
        flock 9
        ${lib.optionalString (app.role == "primary") ''
          if prefix_in_use; then
            echo "Refusing a second primary application in $prefix" >&2
            exit 75
          fi
        ''}
        if [ "''${1:-}" = "--check-only" ]; then
          exit 0
        fi

        export WINEPREFIX="$prefix"
        export STEAM_COMPAT_DATA_PATH="$prefix"
        export PROTONPATH=${lib.escapeShellArg (toString app.protonPackage)}
        export GAMEID=${lib.escapeShellArg app.gameId}
        export STORE=${lib.escapeShellArg app.store}
        export PROTON_VERB=${lib.escapeShellArg (
          if app.role == "companion"
          then "runinprefix"
          else "waitforexitandrun"
        )}
        ${environmentExports}

        # The startup decision is complete. Do not make the lifetime of the
        # application itself exclude same-prefix companion launches.
        flock -u 9
        exec ${runCommand} "$executable" ${lib.escapeShellArgs app.arguments}
      '';
    };

    starter = pkgs.writeShellApplication {
      name = "umu-app-${name}";
      runtimeInputs = [
        pkgs.libnotify
        pkgs.systemd
      ];
      text = ''
        unit=${lib.escapeShellArg unitName}
        label=${lib.escapeShellArg app.displayName}

        if systemctl --user --quiet is-active "$unit"; then
          notify-send "$label" "Already running through the direct UMU path"
          exit 0
        fi

        if ! error="$(${lib.getExe runner} --check-only 2>&1)"; then
          notify-send --urgency=critical "$label" \
            "''${error:-Direct launch preflight failed; Heroic remains available}"
          exit 1
        fi

        if ! systemctl --user start "$unit"; then
          notify-send --urgency=critical "$label" \
            "Direct launch failed; Heroic remains available as the QA fallback"
          exit 1
        fi
      '';
    };
  in {
    inherit app runner starter unitName;
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
            Unit.Description = "Direct UMU application: ${application.app.displayName}";
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
