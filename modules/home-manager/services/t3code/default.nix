# modules/home-manager/services/t3code/default.nix
#
# Runs t3code in headless server mode (t3 serve), listening on all interfaces.
# The host firewall controls access to the configured port.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.t3code;
  activationGuard = pkgs.writeShellApplication {
    name = "t3code-activation-guard";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      gnused
      sqlite
      systemd
    ];
    text = ''
      if [[ "''${T3CODE_ALLOW_ACTIVE_RESTART:-0}" == "1" ]]; then
        echo "T3 Code active-session restart guard explicitly bypassed."
        exit 0
      fi

      if ! systemctl --user --quiet is-active t3code.service; then
        exit 0
      fi

      managed_unit="''${T3CODE_MANAGED_UNIT:-$HOME/.config/systemd/user/t3code.service}"
      if [[ ! -r "$managed_unit" ]]; then
        exit 0
      fi

      loaded_exec=$(systemctl --user show t3code.service --property=ExecStart --value \
        | sed -nE 's/^\{ path=([^ ;]+).*/\1/p')
      managed_exec=$(sed -nE 's/^ExecStart=([^ ]+).*/\1/p' "$managed_unit" | head -n1)

      if [[ -z "$loaded_exec" || -z "$managed_exec" ]]; then
        echo "Unable to compare the loaded and managed T3 Code executables; refusing a potentially disruptive restart." >&2
        exit 75
      fi

      if [[ "$loaded_exec" == "$managed_exec" ]]; then
        exit 0
      fi

      database=${escapeShellArg "${cfg.baseDir}/userdata/state.sqlite"}
      if [[ ! -r "$database" ]]; then
        echo "T3 Code executable is changing, but no readable state database exists; continuing."
        exit 0
      fi

      active_sessions() {
        sqlite3 -readonly -cmd '.timeout 5000' "$database" \
          "SELECT count(*) FROM projection_thread_sessions WHERE status IN ('starting', 'running');"
      }

      first_count=$(active_sessions)
      if [[ ! "$first_count" =~ ^[0-9]+$ ]]; then
        echo "Unable to read T3 Code session state; refusing a potentially disruptive restart." >&2
        exit 75
      fi

      if ((first_count > 0)); then
        echo "T3 Code has $first_count active session(s); deferring the Home Manager activation." >&2
        echo "Retry when the turns finish, or set T3CODE_ALLOW_ACTIVE_RESTART=1 for an intentional interruption." >&2
        exit 75
      fi

      sleep ${toString cfg.restartGuard.settleSeconds}
      second_count=$(active_sessions)
      if [[ ! "$second_count" =~ ^[0-9]+$ || "$second_count" != "0" ]]; then
        echo "T3 Code became active during the restart guard window; deferring activation." >&2
        exit 75
      fi

      echo "T3 Code is idle; allowing the managed executable to change."
    '';
  };

  autoUpdate = pkgs.writeShellApplication {
    name = "t3code-auto-update";
    runtimeInputs = with pkgs; [
      git
      nix
      openssh
    ];
    text = ''
      target=${escapeShellArg "${cfg.autoUpdate.flakeUri}#homeConfigurations.${cfg.autoUpdate.homeConfiguration}.activationPackage"}
      echo "Building Home Manager activation from $target"
      activation=$(nix build --refresh --no-link --print-out-paths "$target")
      exec "$activation/activate"
    '';
  };
in {
  options.services.t3code = {
    enable = mkEnableOption "t3code headless server";

    port = mkOption {
      type = types.port;
      default = 3773;
      description = "Port to listen on.";
    };

    host = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = "Interface to bind. Defaults to all interfaces; the NixOS firewall restricts access to Netbird (wt0).";
    };

    baseDir = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.t3";
      description = "Base directory for t3code state (userdata, logs, settings).";
    };

    restartGuard = {
      enable = mkEnableOption "deferring T3 Code package restarts while turns are active" // {default = true;};

      settleSeconds = mkOption {
        type = types.ints.positive;
        default = 10;
        description = "Seconds T3 Code must remain idle before Home Manager may restart it with a changed executable.";
      };
    };

    autoUpdate = {
      enable = mkEnableOption "unattended Home Manager updates for the host running T3 Code";

      flakeUri = mkOption {
        type = types.str;
        example = "git+https://code.example.net/operator/nix-config.git?ref=dev";
        description = "Flake URI to refresh and build. The URI must not contain a fragment.";
      };

      homeConfiguration = mkOption {
        type = types.str;
        description = "Home Manager configuration attribute to activate.";
      };

      calendar = mkOption {
        type = types.str;
        default = "*-*-* 04:00:00";
        description = "systemd OnCalendar expression for unattended updates.";
      };

      randomizedDelaySec = mkOption {
        type = types.str;
        default = "30m";
        description = "Maximum randomized delay applied to the update timer.";
      };
    };
  };

  config = mkIf cfg.enable {
    systemd.user.services.t3code = {
      Unit = {
        Description = "t3code headless server";
        After = ["network-online.target"];
        Wants = ["network-online.target"];
      };
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.t3code}/bin/t3 serve --host ${cfg.host} --port ${toString cfg.port} --base-dir ${cfg.baseDir}";
        Environment = "SHELL=${pkgs.bash}/bin/bash";
        # A clean provider/server exit is still unexpected for a persistent
        # headless environment. Systemd stop operations suppress restarts.
        Restart = "always";
        RestartSec = "10s";
        StandardOutput = "journal";
        StandardError = "journal";
      };
      Install.WantedBy = ["default.target"];
    };

    home.activation.t3codeRestartGuard = mkIf cfg.restartGuard.enable (
      lib.hm.dag.entryBetween ["reloadSystemd"] ["linkGeneration"] ''
        run ${activationGuard}/bin/t3code-activation-guard
      ''
    );

    systemd.user.services.t3code-auto-update = mkIf cfg.autoUpdate.enable {
      Unit = {
        Description = "Refresh and activate the configured Home Manager generation";
        After = ["network-online.target"];
        Wants = ["network-online.target"];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${autoUpdate}/bin/t3code-auto-update";
        TimeoutStartSec = "3h";
      };
    };

    systemd.user.timers.t3code-auto-update = mkIf cfg.autoUpdate.enable {
      Unit.Description = "Nightly Home Manager update for T3 Code and its providers";
      Timer = {
        OnCalendar = cfg.autoUpdate.calendar;
        RandomizedDelaySec = cfg.autoUpdate.randomizedDelaySec;
        Persistent = true;
        Unit = "t3code-auto-update.service";
      };
      Install.WantedBy = ["timers.target"];
    };
  };
}
