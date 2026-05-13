# modules/home-manager/programs/paneru/default.nix
# Paneru — niri/PaperWM-style sliding tiling WM for macOS.
{
  config,
  lib,
  pkgs,
  username,
  ...
}: let
  cfg = config.programs.paneru.managed;
  paneruConfig = "${config.home.homeDirectory}/src/infra/nix-config/users/${username}/configs/paneru/paneru.toml";
  defaultPaneruBin = lib.getExe pkgs.paneru;
  reconcileT3Code = pkgs.writeShellScript "paneru-reconcile-t3code" ''
    set -eu

    state_dir="${config.home.homeDirectory}/.local/state/paneru"
    state_file="$state_dir/t3code-pid"

    mkdir -p "$state_dir"

    pid="$(
      /bin/ps ax -o pid= -o command= \
        | /usr/bin/awk '/\/Applications\/T3 Code \(Alpha\)\.app\/Contents\/MacOS\/T3 Code \(Alpha\)$/ { print $1; exit }'
    )"

    if [ -z "$pid" ]; then
      rm -f "$state_file"
      exit 0
    fi

    if [ -f "$state_file" ] && [ "$(<"$state_file")" = "$pid" ]; then
      exit 0
    fi

    printf '%s\n' "$pid" > "$state_file"
    /bin/sleep 2
    /bin/launchctl kickstart -k "gui/$(/usr/bin/id -u)/org.nix-community.home.paneru"
  '';
in {
  options.programs.paneru.managed = {
    enable = lib.mkEnableOption "Manage Paneru configuration and launchd agent";

    command = lib.mkOption {
      type = lib.types.str;
      default = defaultPaneruBin;
      description = "Path to the Paneru binary.";
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile."paneru/paneru.toml".source = config.lib.file.mkOutOfStoreSymlink paneruConfig;

    home.activation.removeHomebrewPaneruAgent = lib.hm.dag.entryAfter ["writeBoundary"] ''
      launchctl bootout "gui/$UID/com.github.karinushka.paneru" 2>/dev/null || true
      launchctl disable "gui/$UID/com.github.karinushka.paneru" 2>/dev/null || true
      rm -f "${config.home.homeDirectory}/Library/LaunchAgents/com.github.karinushka.paneru.plist"
    '';

    launchd.agents.paneru = {
      enable = true;
      config = {
        ProgramArguments = [cfg.command];
        RunAtLoad = true;
        KeepAlive = true;
        EnvironmentVariables = {
          PANERU_CONFIG = paneruConfig;
        };
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/paneru.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/paneru.err.log";
      };
    };

    launchd.agents.paneru-reconcile-t3code = {
      enable = true;
      config = {
        ProgramArguments = ["${reconcileT3Code}"];
        RunAtLoad = true;
        StartInterval = 10;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/paneru-reconcile-t3code.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/paneru-reconcile-t3code.err.log";
      };
    };
  };
}
