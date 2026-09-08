{
  app,
  cfg,
  lib,
  name,
  pkgs,
}: let
  unitName = "umu-app-${name}.service";
  prefixLock = builtins.substring 0 20 (builtins.hashString "sha256" app.prefix);
  staleRecoveryEnabled = app.role == "primary" && app.staleRecoveryWindowMatchers != [];
  staleRecoveryMatchers = builtins.toJSON app.staleRecoveryWindowMatchers;
  samePrefixCompanionUnits =
    lib.mapAttrsToList (
      companionName: _: "umu-app-${companionName}.service"
    ) (lib.filterAttrs (
        companionName: companion:
          companionName
          != name
          && companion.prefix == app.prefix
          && companion.role == "companion"
      )
      cfg.apps);
  samePrefixCompanionCheck =
    lib.concatMapStrings (companionUnit: ''
      if systemctl --user --quiet is-active ${lib.escapeShellArg companionUnit}; then
        return 0
      fi
    '')
    samePrefixCompanionUnits;
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

  runnerText = ''
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

  runner = pkgs.writeShellApplication {
    name = "umu-app-${name}-run";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.util-linux
    ];
    text = runnerText;
  };

  starterText = ''
    unit=${lib.escapeShellArg unitName}
    label=${lib.escapeShellArg app.displayName}

    if systemctl --user --quiet is-active "$unit"; then
      ${
      if staleRecoveryEnabled
      then ''
                    clients="$(hyprctl clients -j 2>/dev/null || true)"
                    if ! jq -e 'type == "array"' <<<"$clients" >/dev/null 2>&1; then
                      notify-send --urgency=critical "$label" \
                        "Already running; unable to verify its windows safely"
                      exit 1
                    fi

                    if jq -e --argjson matchers ${lib.escapeShellArg staleRecoveryMatchers} '
                      any(.[];
                        . as $client
                        | any($matchers[];
                            . as $matcher
                            | (($client.class // "") | test($matcher.classRegex))
                            and (($client.title // "") | test($matcher.titleRegex))))
                    ' <<<"$clients" >/dev/null; then
                      notify-send "$label" "Already running through the direct UMU path"
                      exit 0
                    fi

                    same_prefix_companion_active() {
        ${samePrefixCompanionCheck}              return 1
                    }

                    if same_prefix_companion_active; then
                      notify-send --urgency=critical "$label" \
                        "No managed window is visible, but a same-prefix companion is active; refusing recovery"
                      exit 1
                    fi

                    entered_us="$(systemctl --user show "$unit" \
                      --property=ActiveEnterTimestampMonotonic --value)"
                    now_seconds="$(cut -d. -f1 /proc/uptime)"
                    if [[ "$entered_us" =~ ^[0-9]+$ ]] \
                      && ((now_seconds * 1000000 - entered_us < ${toString app.staleRecoveryGraceSeconds} * 1000000)); then
                      notify-send "$label" "Still starting; waiting for its window"
                      exit 0
                    fi

                    notify-send "$label" "No managed window remains; restarting the stale service"
                    if ! systemctl --user restart "$unit"; then
                      notify-send --urgency=critical "$label" \
                        "Stale-service recovery failed; Heroic remains available as the QA fallback"
                      exit 1
                    fi
                    exit 0
      ''
      else ''
        notify-send "$label" "Already running through the direct UMU path"
        exit 0
      ''
    }
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

  starter = pkgs.writeShellApplication {
    name = "umu-app-${name}";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.jq
      pkgs.libnotify
      pkgs.systemd
    ];
    text = starterText;
  };
in {
  inherit app runner starter unitName;
}
