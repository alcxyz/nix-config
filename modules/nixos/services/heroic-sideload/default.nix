# nix-config/modules/nixos/services/heroic-sideload/default.nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.heroicSideload;
  format = pkgs.formats.json {};

  appType = lib.types.submodule ({name, ...}: {
    options = {
      title = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Display title in Heroic.";
      };

      appName = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Stable Heroic app identifier.";
      };

      executable = lib.mkOption {
        type = lib.types.str;
        description = "Executable path relative to the installed game directory.";
      };

      installDir = lib.mkOption {
        type = lib.types.path;
        description = "Directory where the game should be installed.";
      };

      source = lib.mkOption {
        type = lib.types.path;
        description = "Source directory or zip file to copy/extract into installDir.";
      };

      art = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional cover/square artwork URL for Heroic.";
      };
    };
  });

  mkLibraryGame = app: {
    runner = "sideload";
    app_name = app.appName;
    title = app.title;
    install = {
      executable = "${app.installDir}/${app.executable}";
      platform = "Windows";
      is_dlc = false;
    };
    folder_name = toString app.installDir;
    art_cover = app.art or "";
    is_installed = true;
    art_square = app.art or "";
    canRunOffline = true;
    browserUrl = "";
    customUserAgent = "";
    launchFullScreen = false;
  };

  mkGameConfig = app: {
    ${app.appName} = {
      autoInstallDxvk = true;
      autoInstallDxvkNvapi = true;
      autoInstallVkd3d = true;
      preferSystemLibs = false;
      enableEsync = true;
      enableMsync = false;
      enableFsync = true;
      enableWineWayland = false;
      enableHDR = false;
      enableWoW64 = false;
      nvidiaPrime = false;
      enviromentOptions = [];
      wrapperOptions = [];
      showFps = false;
      useGameMode = true;
      battlEyeRuntime = true;
      eacRuntime = true;
      language = "";
      beforeLaunchScriptPath = "";
      afterLaunchScriptPath = "";
      verboseLogs = false;
      advertiseAvxForRosetta = false;
      wineVersion = {};
      winePrefix = "${config.users.users.${cfg.user}.home}/Games/Heroic/Prefixes/default/${app.title}";
      wineCrossoverBottle = "";
    };
    version = "v0";
    explicit = true;
  };

  libraryFile = format.generate "heroic-sideload-library.json" {
    games = map mkLibraryGame (lib.attrValues cfg.apps);
  };

  gameConfigFiles =
    lib.mapAttrsToList (
      _: app: {
        inherit app;
        file = format.generate "heroic-${app.appName}.json" (mkGameConfig app);
      }
    )
    cfg.apps;
in {
  options.services.heroicSideload = {
    enable = lib.mkEnableOption "Heroic sideloaded game repair";

    user = lib.mkOption {
      type = lib.types.str;
      description = "User whose Heroic Flatpak config should be managed.";
    };

    apps = lib.mkOption {
      type = lib.types.attrsOf appType;
      default = {};
      description = "Sideloaded Heroic games to install and register.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.heroic-sideload = {
      description = "Install and register Heroic sideloaded games";
      after = ["local-fs.target"];
      wantedBy = ["multi-user.target"];
      path = with pkgs; [
        coreutils
        gnugrep
        jq
        unzip
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        set -euo pipefail

        user=${lib.escapeShellArg cfg.user}
        home=${lib.escapeShellArg config.users.users.${cfg.user}.home}
        heroic_config="$home/.var/app/com.heroicgameslauncher.hgl/config/heroic"

        install -d -m755 "$home/Games" "$heroic_config/sideload_apps" "$heroic_config/GamesConfig"

        ${lib.concatMapStringsSep "\n" (app: ''
            source_path=${lib.escapeShellArg (toString app.source)}
            install_dir=${lib.escapeShellArg (toString app.installDir)}

            install -d -m755 "$install_dir"
            if [ -d "$source_path" ]; then
              cp -aT "$source_path" "$install_dir"
            elif [ -f "$source_path" ] && printf '%s\n' "$source_path" | grep -qi '\.zip$'; then
              unzip -oq "$source_path" -d "$install_dir"
            else
              echo "heroic-sideload: missing source $source_path" >&2
            fi

            chown -R "$user:users" "$install_dir"
          '')
          (lib.attrValues cfg.apps)}

        library_target="$heroic_config/sideload_apps/library.json"
        if [ -f "$library_target" ]; then
          tmp="$(mktemp)"
          jq -s '
            .[0].games as $managed
            | (.[1].games // []) as $existing
            | ($managed | map(.app_name)) as $managed_ids
            | {
                games:
                  (($existing | map(select((.app_name as $id | $managed_ids | index($id)) | not))) + $managed)
              }
          ' ${libraryFile} "$library_target" > "$tmp"
          install -m644 "$tmp" "$library_target"
          rm -f "$tmp"
        else
          install -m644 ${libraryFile} "$library_target"
        fi

        ${lib.concatMapStringsSep "\n" (entry: "install -m644 ${entry.file} \"$heroic_config/GamesConfig/${entry.app.appName}.json\"")
          gameConfigFiles}

        chown -R "$user:users" "$home/Games" "$heroic_config"
      '';
    };
  };
}
