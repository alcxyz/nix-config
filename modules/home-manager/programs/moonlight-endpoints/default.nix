{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.moonlightEndpoints;
  preferenceDomain = "com.moonlight-stream.Moonlight";
  preferenceFile = "${config.home.homeDirectory}/Library/Preferences/${preferenceDomain}.plist";
  policy = pkgs.writeText "moonlight-endpoint-policy.json" (builtins.toJSON cfg.hosts);
  plist = pkgs.formats.plist {};

  selectEndpoint = pkgs.writeShellApplication {
    name = "moonlight-select-endpoint";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      set -eu

      if [ "$#" -ne 2 ]; then
        echo "usage: moonlight-select-endpoint HOSTNAME lan|vpn" >&2
        exit 2
      fi

      hostname="$1"
      mode="$2"
      preference_file=${lib.escapeShellArg preferenceFile}
      if [ ! -f "$preference_file" ]; then
        echo "Moonlight has not created its preferences yet" >&2
        exit 1
      fi

      host="$(jq -ce --arg hostname "$hostname" \
        'first(.[] | select(.hostname == $hostname))' ${policy})"
      case "$mode" in
        lan) address="$(printf '%s\n' "$host" | jq -r .localAddress)" ;;
        vpn) address="$(printf '%s\n' "$host" | jq -r .remoteAddress)" ;;
        *)
          echo "unsupported Moonlight endpoint mode: $mode" >&2
          exit 2
          ;;
      esac

      host_count="$(
        /usr/bin/defaults read ${lib.escapeShellArg preferenceDomain} "hosts.size" \
          2>/dev/null || printf '0\n'
      )"
      index=""
      for candidate in $(seq 1 "$host_count"); do
        current_hostname="$(
          /usr/bin/defaults read ${lib.escapeShellArg preferenceDomain} \
            "hosts.$candidate.hostname" 2>/dev/null || true
        )"
        if [ "$current_hostname" = "$hostname" ]; then
          index="$candidate"
          break
        fi
      done
      if [ -z "$index" ]; then
        echo "Moonlight paired host not found: $hostname" >&2
        exit 1
      fi

      # Pin every candidate field to one endpoint. Discovery and stale saved
      # preferences therefore cannot move an explicitly selected LAN stream
      # onto VPN, or a VPN stream back onto LAN.
      for field in localaddress manualaddress remoteaddress; do
        /usr/bin/defaults write ${lib.escapeShellArg preferenceDomain} \
          "hosts.$index.$field" -string "$address"
      done

      printf '%s\n' "$address"
    '';
  };

  mkLauncher = launcher: mode: let
    routeLabel =
      if mode == "lan"
      then "LAN"
      else "VPN";
    displayName = "${launcher.hostname} (${routeLabel})";
    slug = lib.toLower (
      builtins.replaceStrings [" " "." "_"] ["-" "-" "-"] launcher.hostname
    );
    commandName = "moonlight-${slug}-${mode}";
    command = pkgs.writeShellApplication {
      name = commandName;
      text = ''
        address="$(${lib.getExe selectEndpoint} \
          ${lib.escapeShellArg launcher.hostname} ${lib.escapeShellArg mode})"
        exec ${lib.getExe pkgs.moonlight-qt} \
          ${lib.escapeShellArgs launcher.arguments} \
          stream "$address" ${lib.escapeShellArg launcher.application}
      '';
    };
    infoPlist = plist.generate "${commandName}-Info.plist" {
      CFBundleDisplayName = displayName;
      CFBundleExecutable = commandName;
      CFBundleIdentifier = "xyz.alc.moonlight.${slug}.${mode}";
      CFBundleName = displayName;
      CFBundlePackageType = "APPL";
      CFBundleVersion = "1";
      LSMinimumSystemVersion = "12.0";
      NSHighResolutionCapable = true;
    };
    app = pkgs.runCommand "${commandName}-app" {} ''
      app="$out/Applications/${displayName}.app"
      mkdir -p "$app/Contents/MacOS"
      ln -s ${lib.getExe command} "$app/Contents/MacOS/${commandName}"
      ln -s ${infoPlist} "$app/Contents/Info.plist"
    '';
  in {
    inherit app command;
  };

  launchers =
    lib.concatMap (
      launcher: [
        (mkLauncher launcher "lan")
        (mkLauncher launcher "vpn")
      ]
    )
    cfg.launchers;
in {
  options.programs.moonlightEndpoints = {
    enable = lib.mkEnableOption "explicit Moonlight endpoint launchers on macOS";

    hosts = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            hostname = lib.mkOption {
              type = lib.types.str;
              description = "Moonlight paired-host name and launcher label.";
            };
            localAddress = lib.mkOption {
              type = lib.types.str;
              description = "Address selected by the explicit LAN launcher.";
            };
            remoteAddress = lib.mkOption {
              type = lib.types.str;
              description = "Address selected by the explicit VPN launcher.";
            };
          };
        }
      );
      default = [];
      description = "Private endpoint definitions for paired Moonlight hosts.";
    };

    launchers = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            hostname = lib.mkOption {
              type = lib.types.str;
              description = "Paired-host name used by this explicit route launcher.";
            };
            application = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Moonlight application launched by both route entries.";
            };
            arguments = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = ["--absolute-mouse"];
              description = "Moonlight options placed before the stream command.";
            };
          };
        }
      );
      default = [];
      description = "Applications exposed as separate HOST (LAN) and HOST (VPN) bundles.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "programs.moonlightEndpoints is currently supported only on macOS";
      }
      {
        assertion = lib.length cfg.hosts == lib.length (lib.unique (map (host: host.hostname) cfg.hosts));
        message = "programs.moonlightEndpoints hostnames must be unique";
      }
      {
        assertion =
          lib.all (
            launcher: lib.elem launcher.hostname (map (host: host.hostname) cfg.hosts)
          )
          cfg.launchers;
        message = "programs.moonlightEndpoints launchers must reference a configured host";
      }
    ];

    home.packages =
      [selectEndpoint]
      ++ map (launcher: launcher.command) launchers
      ++ map (launcher: launcher.app) launchers;
  };
}
