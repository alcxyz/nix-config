# modules/home-manager/services/t3code/default.nix
#
# Runs t3code in headless server mode (t3 serve), listening on all interfaces,
# plus any additional instances. The host firewall controls access to the
# configured ports.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.t3code;
  managedVersion = getVersion cfg.package;
  managedChannel =
    if cfg.channel == "fork"
    then "fork-${cfg.forkReleaseChannel}"
    else "upstream";
  managedVersionState = "${cfg.baseDir}/userdata/managed-t3code-version";
  managedChannelState = "${cfg.baseDir}/userdata/managed-t3code-channel";
  restartMarker = "${cfg.baseDir}/userdata/managed-t3code-restart-required";
  # With unattended updates, T3 and its providers live in a profile the
  # updater replaces without Home Manager activation (ADR-0077).
  profileMode = cfg.autoUpdate.enable;
  aiStackProfile = "${config.home.homeDirectory}/.local/state/nix/profiles/ai-stack";
  seedBundle = pkgs."ai-stack-${managedChannel}";
  t3Executable =
    if profileMode
    then "${aiStackProfile}/bin/t3"
    else "${cfg.package}/bin/t3";
  # The primary server keeps the historical unit name and state. Additional
  # instances share its executable, so the guards below cover all of them.
  instances =
    [
      {
        unit = "t3code";
        description = "t3code headless server";
        inherit (cfg) port baseDir;
      }
    ]
    ++ mapAttrsToList (name: instance: {
      unit = "t3code-${name}";
      description = "t3code headless server (${name})";
      inherit (instance) port baseDir;
    })
    cfg.instances;
  unitNames = map (instance: "${instance.unit}.service") instances;
  # Instance names are restricted to [a-z0-9-], so the list needs no quoting.
  unitArgs = concatStringsSep " " unitNames;
  serviceCgroupPattern = "(^|/)(${concatMapStringsSep "|" escapeRegex unitNames})(/|$)";
  # Prints the starting or running turn count summed over every instance's
  # state database. A missing database counts as idle; an unreadable one makes
  # the result non-numeric, which callers treat as busy.
  activeSessionsFunction = ''
    state_databases=(${escapeShellArgs (map (instance: "${instance.baseDir}/userdata/state.sqlite") instances)})
    if [[ -n "''${T3CODE_STATE_DATABASE:-}" ]]; then
      state_databases=("$T3CODE_STATE_DATABASE")
    fi
    active_sessions() {
      local total=0 database count
      for database in "''${state_databases[@]}"; do
        if [[ ! -r "$database" ]]; then
          continue
        fi
        count=$(sqlite3 -readonly -cmd '.timeout 5000' "$database" \
          "SELECT count(*) FROM projection_thread_sessions WHERE status IN ('starting', 'running');") || count=""
        if [[ ! "$count" =~ ^[0-9]+$ ]]; then
          echo unreadable
          return
        fi
        total=$((total + count))
      done
      echo "$total"
    }
  '';
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
      managed_channel=${escapeShellArg managedChannel}
      channel_state="''${T3CODE_CHANNEL_STATE:-${managedChannelState}}"
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

      # Every running instance shares the managed executable, so each one's
      # loaded version counts towards the downgrade check and the restart.
      loaded_execs=()
      for unit in ${unitArgs}; do
        if ! systemctl --user --quiet is-active "$unit"; then
          continue
        fi
        loaded_exec=$(systemctl --user show "$unit" --property=ExecStart --value \
          | sed -nE 's/^\{ path=([^ ;]+).*/\1/p')
        loaded_execs+=("$loaded_exec")
        loaded_version=$(sed -nE 's#^/nix/store/[a-z0-9]+-t3code-([^/]+)/bin/t3$#\1#p' <<<"$loaded_exec")
        if [[ -n "$loaded_version" ]] \
          && { [[ -z "$accepted_version" ]] || version_is_older "$accepted_version" "$loaded_version"; }; then
          accepted_version=$loaded_version
        fi
      done

      accepted_channel=upstream
      if [[ -r "$channel_state" ]]; then
        read -r accepted_channel < "$channel_state" || true
      fi
      if [[ "$accepted_channel" != upstream && "$accepted_channel" != fork && "$accepted_channel" != fork-nightly && "$accepted_channel" != fork-stable ]]; then
        echo "Invalid managed T3 Code channel state at $channel_state." >&2
        exit 76
      fi

      # Legacy fork selection follows the nightly compatibility alias.
      if [[ "$accepted_channel" == fork ]]; then
        accepted_channel=fork-nightly
      fi

      # Selecting another channel is an intentional package change. Versions
      # from independent release lines cannot be ordered as ordinary updates.
      if [[ "$accepted_channel" == "$managed_channel" && -n "$accepted_version" ]] && version_is_older "$managed_version" "$accepted_version"; then
        if [[ "''${T3CODE_ALLOW_DOWNGRADE:-0}" != "1" ]]; then
          echo "Refusing to downgrade managed T3 Code from $accepted_version to $managed_version." >&2
          echo "Promote the newer nix-packages revision into flake.lock, or set T3CODE_ALLOW_DOWNGRADE=1 for an intentional rollback." >&2
          exit 76
        fi
        echo "T3 Code downgrade from $accepted_version to $managed_version explicitly allowed." >&2
      fi

      if ((''${#loaded_execs[@]} == 0)); then
        exit 0
      fi

      managed_unit="''${T3CODE_MANAGED_UNIT:-$HOME/.config/systemd/user/t3code.service}"
      if [[ ! -r "$managed_unit" ]]; then
        exit 0
      fi

      managed_exec=$(sed -nE 's/^ExecStart=([^ ]+).*/\1/p' "$managed_unit" | head -n1)

      restart_needed=false
      for loaded_exec in "''${loaded_execs[@]}"; do
        if [[ -z "$loaded_exec" || -z "$managed_exec" ]]; then
          echo "Unable to compare the loaded and managed T3 Code executables; refusing a potentially disruptive restart." >&2
          exit 75
        fi
        if [[ "$loaded_exec" != "$managed_exec" ]]; then
          restart_needed=true
        fi
      done
      if [[ "$restart_needed" != true ]]; then
        exit 0
      fi

      if grep -qE ${escapeShellArg serviceCgroupPattern} "$cgroup_file"; then
        echo "Refusing to restart T3 Code from a process running inside a T3 Code service." >&2
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

      ${activeSessionsFunction}
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

  # Exits 0 once T3 has no starting or running turns for the settle window,
  # 75 (retry later) otherwise.
  idleCheck = pkgs.writeShellApplication {
    name = "t3code-idle-check";
    runtimeInputs = with pkgs; [coreutils sqlite];
    text = ''
      if [[ "''${T3CODE_ALLOW_ACTIVE_RESTART:-0}" == "1" ]]; then
        echo "T3 Code active-session guard explicitly bypassed."
        exit 0
      fi
      ${activeSessionsFunction}
      count=$(active_sessions)
      if [[ "$count" == 0 ]]; then
        sleep "''${T3CODE_SETTLE_SECONDS:-${toString cfg.restartGuard.settleSeconds}}"
        count=$(active_sessions)
      fi
      if [[ "$count" != 0 ]]; then
        echo "T3 Code is busy or its session state is unreadable ($count); deferring the restart." >&2
        echo "Retry when the turns finish, or set T3CODE_ALLOW_ACTIVE_RESTART=1 for an intentional interruption." >&2
        exit 75
      fi
    '';
  };

  # ADR-0077: switch the AI stack profile to a built bundle, refusing
  # same-channel downgrades and restarting T3 only when it is idle.
  aiStackSwitch = pkgs.writeShellApplication {
    name = "t3code-ai-stack-switch";
    runtimeInputs = with pkgs; [
      coreutils
      gnused
      nix
      systemd
    ];
    text = ''
      candidate=$1
      profile="''${T3CODE_AI_STACK_PROFILE:-${aiStackProfile}}"
      channel=${escapeShellArg managedChannel}
      current=""
      if [[ -e "$profile" ]]; then
        current=$(readlink -f "$profile")
      fi
      if [[ "$candidate" == "$current" ]]; then
        echo "The AI stack profile is already current."
        exit 0
      fi

      t3_version() {
        { readlink "$1/bin/t3" || true; } | sed -nE 's#^/nix/store/[a-z0-9]+-t3code-([^/]+)/bin/t3$#\1#p'
      }
      current_channel=$(sed -nE 's#^/nix/store/[a-z0-9]+-ai-stack-(.+)$#\1#p' <<<"$current")
      new_version=$(t3_version "$candidate")
      old_version=""
      if [[ -n "$current" ]]; then
        old_version=$(t3_version "$current")
      fi
      if [[ -z "$new_version" ]]; then
        echo "Cannot read the T3 Code version of $candidate." >&2
        exit 76
      fi
      if [[ "$current_channel" == "$channel" && -n "$old_version" && "$new_version" != "$old_version" ]] \
        && [[ "$(printf '%s\n%s\n' "$new_version" "$old_version" | sort -V | head -n1)" == "$new_version" ]] \
        && [[ "''${T3CODE_ALLOW_DOWNGRADE:-0}" != "1" ]]; then
        echo "Refusing to downgrade T3 Code from $old_version to $new_version." >&2
        echo "Set T3CODE_ALLOW_DOWNGRADE=1 for an intentional rollback." >&2
        exit 76
      fi

      summary="$candidate (T3 ''${old_version:-none} -> $new_version)"
      if [[ "''${T3CODE_AUTO_UPDATE_DRY_RUN:-0}" == "1" ]]; then
        echo "Dry run complete; would switch the AI stack to $summary."
        exit 0
      fi

      t3_active=false
      if systemctl --user --quiet is-active ${unitArgs}; then
        t3_active=true
        ${idleCheck}/bin/t3code-idle-check
      fi
      nix-env --profile "$profile" --set "$candidate"
      echo "Switched the AI stack to $summary."
      if [[ "$t3_active" == true ]]; then
        # Instances share the profile; restart the running ones together.
        systemctl --user try-restart ${unitArgs}
      fi
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
      channel=${escapeShellArg managedChannel}
      package_flake_default=${escapeShellArg cfg.autoUpdate.packageFlakeUri}
      # Pin the moving ref once, so the build and the log name one revision.
      package_flake=$(nix flake metadata --refresh --json "''${T3CODE_PACKAGE_FLAKE:-$package_flake_default}" | jq -er .url)
      echo "Building ai-stack-$channel from $package_flake"
      candidate=$(nix build --no-link --print-out-paths "$package_flake#ai-stack-$channel")
      exec ${aiStackSwitch}/bin/t3code-ai-stack-switch "$candidate"
    '';
  };
in {
  options.services.t3code = {
    enable = mkEnableOption "t3code headless server";

    channel = mkOption {
      type = types.enum ["upstream" "fork"];
      default = "upstream";
      description = "Package channel for the existing service. Changing channels preserves its address and state directory.";
    };

    forkReleaseChannel = mkOption {
      type = types.enum ["nightly" "stable"];
      default = "nightly";
      description = "Published upstream release channel used by the tested fork. Applies when channel is fork.";
    };

    package = mkOption {
      type = types.package;
      default =
        if cfg.channel == "fork"
        then
          (
            if cfg.forkReleaseChannel == "stable"
            then pkgs.t3code-fork-stable
            else pkgs.t3code-fork
          )
        else pkgs.t3code;
      defaultText = literalExpression ''if config.services.t3code.channel == "fork" then (if config.services.t3code.forkReleaseChannel == "stable" then pkgs.t3code-fork-stable else pkgs.t3code-fork) else pkgs.t3code'';
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

    instances = mkOption {
      type = types.attrsOf (types.submodule ({name, ...}: {
        options = {
          port = mkOption {
            type = types.port;
            description = "Port this instance listens on.";
          };
          baseDir = mkOption {
            type = types.str;
            default = "${config.home.homeDirectory}/.t3-${name}";
            defaultText = literalExpression ''"''${config.home.homeDirectory}/.t3-<name>"'';
            description = "Base directory for this instance's state.";
          };
        };
      }));
      default = {};
      example = literalExpression ''{ work.port = 3774; }'';
      description = ''
        Additional servers, each run as `t3code-<name>.service` with its own
        port and state. They share the primary server's package, AI stack
        profile, update timer and restart guards; a restart waits until every
        instance is idle.
      '';
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
      enable = mkEnableOption "unattended T3 Code and provider updates through the ai-stack profile (ADR-0077)";

      packageFlakeUri = mkOption {
        type = types.str;
        example = "git+https://code.example.net/operator/nix-packages.git?ref=promoted";
        description = "nix-packages flake that provides the ai-stack bundles, normally the branch moved by local package promotion (ADR-0080). Each run pins its current revision. The URI must not contain a fragment.";
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
      ++ [
        {
          assertion = all (name: builtins.match "[a-z0-9]+(-[a-z0-9]+)*" name != null && name != "auto-update") (attrNames cfg.instances);
          message = "services.t3code.instances names must match [a-z0-9]+(-[a-z0-9]+)* and must not be auto-update.";
        }
        {
          assertion = allUnique (map (instance: instance.port) instances);
          message = "services.t3code instances must use distinct ports.";
        }
        {
          assertion = allUnique (map (instance: instance.baseDir) instances);
          message = "services.t3code instances must use distinct base directories.";
        }
      ];

    systemd.user.services = mkMerge [
      (listToAttrs (map (instance:
        nameValuePair instance.unit {
          Unit = {
            Description = instance.description;
            After = ["network-online.target"];
            Wants = ["network-online.target"];
            # Home Manager's service switch must never restart T3 implicitly. The
            # activation guard records an approved executable change and the
            # post-reload activation step applies that restart explicitly.
            X-RestartIfChanged = !cfg.restartGuard.enable;
          };
          Service = {
            Type = "simple";
            ExecStart = "${t3Executable} serve --host ${cfg.host} --port ${toString instance.port} --base-dir ${instance.baseDir}";
            Environment = "SHELL=${pkgs.bash}/bin/bash";
            # A clean provider/server exit is still unexpected for a persistent
            # headless environment. Systemd stop operations suppress restarts.
            Restart = "always";
            RestartSec = "10s";
            StandardOutput = "journal";
            StandardError = "journal";
          };
          Install.WantedBy = ["default.target"];
        })
      instances))
      {
        t3code-auto-update = mkIf cfg.autoUpdate.enable {
          Unit = {
            Description = "Refresh the T3 Code and AI provider profile";
            After = ["network-online.target"];
            Wants = ["network-online.target"];
            # A Home Manager deploy must not kill an update midway through a
            # profile switch or T3 restart.
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
      }
    ];

    home.sessionPath = mkIf profileMode ["${aiStackProfile}/bin"];
    home.packages = mkIf profileMode [aiStackSwitch];

    # Seed the profile on first deployment or a channel change. After that
    # the updater owns it, so a deploy never rolls the AI stack back.
    home.activation.t3codeSeedAiStack = mkIf profileMode (
      lib.hm.dag.entryBetween ["reloadSystemd"] ["writeBoundary"] ''
        profile=${escapeShellArg aiStackProfile}
        current=""
        if [[ -e "$profile" ]]; then
          current=$(readlink -f "$profile")
        fi
        current_channel=$(${pkgs.gnused}/bin/sed -nE 's#^/nix/store/[a-z0-9]+-ai-stack-(.+)$#\1#p' <<<"$current")
        if [[ -z "$current" || "$current_channel" != ${escapeShellArg managedChannel} ]]; then
          run ${pkgs.nix}/bin/nix-env --profile "$profile" --set ${seedBundle}
          if ${pkgs.systemd}/bin/systemctl --user --quiet is-active ${unitArgs}; then
            if ${idleCheck}/bin/t3code-idle-check; then
              run mkdir -p "$(dirname ${escapeShellArg restartMarker})"
              run touch ${escapeShellArg restartMarker}
            else
              warnEcho "T3 Code is busy; restart the running T3 Code services (${unitArgs}) later to use the seeded AI stack."
            fi
          fi
        fi
      ''
    );

    home.activation.t3codeRestartGuard = mkIf (cfg.restartGuard.enable && !profileMode) (
      lib.hm.dag.entryBetween ["reloadSystemd"] ["linkGeneration"] ''
        run ${activationGuard}/bin/t3code-activation-guard
      ''
    );

    home.activation.t3codeApplyManagedUnit = mkIf cfg.restartGuard.enable (
      lib.hm.dag.entryAfter ["reloadSystemd"] ''
        restart_marker=${escapeShellArg restartMarker}
        if [[ -e "$restart_marker" ]]; then
          cgroup_file="''${T3CODE_CGROUP_FILE:-/proc/self/cgroup}"
          if grep -qE ${escapeShellArg serviceCgroupPattern} "$cgroup_file"; then
            errorEcho "Refusing to restart T3 Code from inside its own service cgroup."
            exit 75
          fi
          # Instances share the executable; restart the running ones together.
          run ${pkgs.systemd}/bin/systemctl --user try-restart ${unitArgs}
          run rm -f "$restart_marker"
        fi
      ''
    );

    home.activation.t3codeRecordManagedVersion = mkIf (!profileMode) (
      lib.hm.dag.entryAfter (
        ["reloadSystemd"] ++ optional cfg.restartGuard.enable "t3codeApplyManagedUnit"
      ) ''
        version_state=${escapeShellArg managedVersionState}
        run mkdir -p "$(dirname "$version_state")"
        tmp=$(mktemp "''${version_state}.XXXXXX")
        printf '%s\n' ${escapeShellArg managedVersion} > "$tmp"
        chmod 0644 "$tmp"
        run mv -f "$tmp" "$version_state"
        channel_state=${escapeShellArg managedChannelState}
        channel_tmp=$(mktemp "''${channel_state}.XXXXXX")
        printf '%s\n' ${escapeShellArg managedChannel} > "$channel_tmp"
        chmod 0644 "$channel_tmp"
        run mv -f "$channel_tmp" "$channel_state"
      ''
    );

    systemd.user.timers.t3code-auto-update = mkIf cfg.autoUpdate.enable {
      Unit.Description = "Scheduled AI stack profile update for T3 Code and its providers";
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
