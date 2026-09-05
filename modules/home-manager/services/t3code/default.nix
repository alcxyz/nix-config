# modules/home-manager/services/t3code/default.nix
#
# Runs t3code in headless server mode (t3 serve), listening on all interfaces.
# The host firewall controls access to the configured port.
{
  config,
  configDir,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.t3code;
  managedVersion = getVersion cfg.package;
  managedVersionState = "${cfg.baseDir}/userdata/managed-t3code-version";
  restartMarker = "${cfg.baseDir}/userdata/managed-t3code-restart-required";
  promotionFlakeDefault =
    if cfg.autoUpdate.promotionFlakeUri == null
    then ""
    else cfg.autoUpdate.promotionFlakeUri;
  configurationSource =
    if builtins.isAttrs configDir && configDir ? outPath
    then configDir.outPath
    else toString configDir;
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
      managed_version=${escapeShellArg managedVersion}
      version_state="''${T3CODE_VERSION_STATE:-${managedVersionState}}"
      restart_marker="''${T3CODE_RESTART_MARKER:-${restartMarker}}"
      cgroup_file="''${T3CODE_CGROUP_FILE:-/proc/self/cgroup}"
      rm -f "$restart_marker"

      version_is_older() {
        local candidate=$1
        local accepted=$2
        [[ "$candidate" != "$accepted" ]] \
          && [[ "$(printf '%s\n%s\n' "$candidate" "$accepted" | sort -V | head -n1)" == "$candidate" ]]
      }

      accepted_version=""
      if [[ -r "$version_state" ]]; then
        read -r accepted_version < "$version_state" || true
        if [[ ! "$accepted_version" =~ ^[0-9][0-9A-Za-z._+-]*$ ]]; then
          echo "Ignoring invalid managed T3 Code version state at $version_state." >&2
          accepted_version=""
        fi
      fi

      loaded_exec=""
      if systemctl --user --quiet is-active t3code.service; then
        loaded_exec=$(systemctl --user show t3code.service --property=ExecStart --value \
          | sed -nE 's/^\{ path=([^ ;]+).*/\1/p')
        loaded_version=$(sed -nE 's#^/nix/store/[a-z0-9]+-t3code-([^/]+)/bin/t3$#\1#p' <<<"$loaded_exec")
        if [[ -n "$loaded_version" ]] \
          && { [[ -z "$accepted_version" ]] || version_is_older "$accepted_version" "$loaded_version"; }; then
          accepted_version=$loaded_version
        fi
      fi

      if [[ -n "$accepted_version" ]] && version_is_older "$managed_version" "$accepted_version"; then
        if [[ "''${T3CODE_ALLOW_DOWNGRADE:-0}" != "1" ]]; then
          echo "Refusing to downgrade managed T3 Code from $accepted_version to $managed_version." >&2
          echo "Promote the newer nix-packages revision into flake.lock, or set T3CODE_ALLOW_DOWNGRADE=1 for an intentional rollback." >&2
          exit 76
        fi
        echo "T3 Code downgrade from $accepted_version to $managed_version explicitly allowed." >&2
      fi

      if ! systemctl --user --quiet is-active t3code.service; then
        exit 0
      fi

      managed_unit="''${T3CODE_MANAGED_UNIT:-$HOME/.config/systemd/user/t3code.service}"
      if [[ ! -r "$managed_unit" ]]; then
        exit 0
      fi

      managed_exec=$(sed -nE 's/^ExecStart=([^ ]+).*/\1/p' "$managed_unit" | head -n1)

      if [[ -z "$loaded_exec" || -z "$managed_exec" ]]; then
        echo "Unable to compare the loaded and managed T3 Code executables; refusing a potentially disruptive restart." >&2
        exit 75
      fi

      if [[ "$loaded_exec" == "$managed_exec" ]]; then
        exit 0
      fi

      if grep -qE '(^|/)t3code\.service(/|$)' "$cgroup_file"; then
        echo "Refusing to restart T3 Code from a process running inside t3code.service." >&2
        echo "Run the activation through t3code-auto-update.service so it can finish independently." >&2
        exit 75
      fi

      allow_managed_restart() {
        mkdir -p "$(dirname "$restart_marker")"
        touch "$restart_marker"
      }

      if [[ "''${T3CODE_ALLOW_ACTIVE_RESTART:-0}" == "1" ]]; then
        echo "T3 Code active-session restart guard explicitly bypassed."
        allow_managed_restart
        exit 0
      fi

      database=${escapeShellArg "${cfg.baseDir}/userdata/state.sqlite"}
      if [[ ! -r "$database" ]]; then
        echo "T3 Code executable is changing, but no readable state database exists; continuing."
        allow_managed_restart
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
      allow_managed_restart
    '';
  };

  autoUpdate = pkgs.writeShellApplication {
    name = "t3code-auto-update";
    runtimeInputs = with pkgs; [
      git
      jq
      nix
      openssh
    ];
    text = ''
      target=${escapeShellArg "${configurationSource}#homeConfigurations.${cfg.autoUpdate.homeConfiguration}.activationPackage"}
      package_flake=${escapeShellArg cfg.autoUpdate.packageFlakeUri}
      promotion_flake_default=${escapeShellArg promotionFlakeDefault}
      promotion_flake="''${T3CODE_PROMOTION_FLAKE:-$promotion_flake_default}"
      if [[ -n "$promotion_flake" ]]; then
        metadata=$(nix flake metadata --refresh --json "$promotion_flake")
        package_flake=$(jq -er '
          .locks.nodes["nix-packages"].locked
          | if .type == "git" and (.url | type) == "string" and (.ref | type) == "string" and (.rev | type) == "string"
            then "git+\(.url)?ref=\(.ref)&rev=\(.rev)"
            else error("promoted nix-packages lock is not a pinned git input")
            end
        ' <<<"$metadata")
        echo "Using the nix-packages revision promoted by $promotion_flake"
      fi
      echo "Building the pinned Home Manager configuration with packages from $package_flake"
      activation=$(
        nix build --no-link --print-out-paths \
          --override-input nix-packages "$package_flake" \
          "$target"
      )
      if [[ "''${T3CODE_AUTO_UPDATE_DRY_RUN:-0}" == "1" ]]; then
        echo "Dry run complete; built $activation without activating it."
        exit 0
      fi
      exec "$activation/activate"
    '';
  };
in {
  options.services.t3code = {
    enable = mkEnableOption "t3code headless server";

    package = mkOption {
      type = types.package;
      default = pkgs.t3code;
      defaultText = literalExpression "pkgs.t3code";
      description = "T3 Code package to run and protect from unintended downgrades.";
    };

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
      enable = mkEnableOption "unattended T3 Code and provider package updates using the pinned Home Manager configuration";

      flakeUri = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Deprecated configuration-flake URI retained for compatibility; unattended activation never evaluates it.";
      };

      packageFlakeUri = mkOption {
        type = types.str;
        example = "git+https://code.example.net/operator/nix-packages.git?ref=dev";
        description = "Flake URI used only to override the nix-packages input of the immutable configuration snapshot. The URI must not contain a fragment.";
      };

      promotionFlakeUri = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "git+https://code.example.net/operator/nix-config.git?ref=dev";
        description = "Configuration flake whose committed nix-packages lock is the package promotion authority. When set, unattended updates use its pinned revision instead of the moving packageFlakeUri ref.";
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
    assertions =
      optional cfg.autoUpdate.enable {
        assertion = !hasInfix "#" cfg.autoUpdate.packageFlakeUri;
        message = "services.t3code.autoUpdate.packageFlakeUri must not contain a fragment.";
      }
      ++ optional (cfg.autoUpdate.enable && cfg.autoUpdate.promotionFlakeUri != null) {
        assertion = !hasInfix "#" cfg.autoUpdate.promotionFlakeUri;
        message = "services.t3code.autoUpdate.promotionFlakeUri must not contain a fragment.";
      };

    systemd.user.services.t3code = {
      Unit = {
        Description = "t3code headless server";
        After = ["network-online.target"];
        Wants = ["network-online.target"];
        # Home Manager's service switch must never restart T3 implicitly. The
        # activation guard records an approved executable change and the
        # post-reload activation step applies that restart explicitly.
        X-RestartIfChanged = !cfg.restartGuard.enable;
      };
      Service = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/t3 serve --host ${cfg.host} --port ${toString cfg.port} --base-dir ${cfg.baseDir}";
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

    home.activation.t3codeApplyManagedUnit = mkIf cfg.restartGuard.enable (
      lib.hm.dag.entryAfter ["reloadSystemd"] ''
        restart_marker=${escapeShellArg restartMarker}
        if [[ -e "$restart_marker" ]]; then
          cgroup_file="''${T3CODE_CGROUP_FILE:-/proc/self/cgroup}"
          if grep -qE '(^|/)t3code\.service(/|$)' "$cgroup_file"; then
            errorEcho "Refusing to restart T3 Code from inside its own service cgroup."
            exit 75
          fi
          run systemctl --user restart t3code.service
          run rm -f "$restart_marker"
        fi
      ''
    );

    home.activation.t3codeRecordManagedVersion =
      lib.hm.dag.entryAfter (
        ["reloadSystemd"] ++ optional cfg.restartGuard.enable "t3codeApplyManagedUnit"
      ) ''
        version_state=${escapeShellArg managedVersionState}
        run mkdir -p "$(dirname "$version_state")"
        tmp=$(mktemp "''${version_state}.XXXXXX")
        printf '%s\n' ${escapeShellArg managedVersion} > "$tmp"
        chmod 0644 "$tmp"
        run mv -f "$tmp" "$version_state"
      '';

    systemd.user.services.t3code-auto-update = mkIf cfg.autoUpdate.enable {
      Unit = {
        Description = "Refresh T3 Code packages within the pinned Home Manager configuration";
        After = ["network-online.target"];
        Wants = ["network-online.target"];
        # This service runs Home Manager activation itself. Its store path can
        # change with the package override being activated, so restarting it
        # from reloadSystemd would terminate that activation midway through.
        X-RestartIfChanged = false;
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${autoUpdate}/bin/t3code-auto-update";
        TimeoutStartSec = "3h";
        Restart = "on-failure";
        RestartForceExitStatus = "75";
        RestartPreventExitStatus = "76";
        RestartSec = "15m";
      };
    };

    systemd.user.timers.t3code-auto-update = mkIf cfg.autoUpdate.enable {
      Unit.Description = "Nightly package-only update for T3 Code and its providers";
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
