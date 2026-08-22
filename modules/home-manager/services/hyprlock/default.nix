{
  config,
  inputs,
  lib,
  pkgs,
  username,
  ...
}:
with lib; let
  cfg = config.services.hyprlock;
  colorscheme = inputs.nix-colors.colorschemes.${config.colorscheme.name};
  colors = colorscheme.palette;

  dpmsScript = pkgs.writeShellScript "hyprland-dpms" ''
    set -eu

    state="''${1:?expected on or off}"
    runtime_dir="''${XDG_RUNTIME_DIR:?}"
    targets_file="$runtime_dir/hyprlock-dpms-outputs"
    exec 8>"$runtime_dir/hyprland-dpms.lock"
    ${pkgs.util-linux}/bin/flock 8

    case "$state" in
      on)
        action=enable
        ;;
      off)
        action=disable
        ;;
      *) exit 2 ;;
    esac

    provider="$(${pkgs.hyprland}/bin/hyprctl status -j 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.configProvider // empty')"
    if [ -s "$targets_file" ]; then
      mapfile -t outputs <"$targets_file"
    else
      mapfile -t outputs < <(
        ${pkgs.hyprland}/bin/hyprctl monitors all -j \
          | ${pkgs.jq}/bin/jq -r '.[] | select(.disabled != true) | .name'
      )
    fi
    ((''${#outputs[@]} > 0)) || {
      echo "hyprland-dpms: no enabled outputs found" >&2
      exit 1
    }

    failed=0
    output_matches() {
      output="$1"
      monitors="$(${pkgs.hyprland}/bin/hyprctl monitors all -j 2>/dev/null || printf '[]\n')"

      if [ "$state" = on ]; then
        ${pkgs.jq}/bin/jq -e --arg output "$output" \
          'any(.[]; .name == $output and .disabled != true and .dpmsStatus == true)' \
          >/dev/null <<<"$monitors"
      else
        ${pkgs.jq}/bin/jq -e --arg output "$output" \
          'all(.[]; if .name == $output then (.disabled == true or .dpmsStatus == false) else true end)' \
          >/dev/null <<<"$monitors"
      fi
    }

    dispatch_output() {
      output="$1"
      if output_matches "$output"; then
        return
      fi

      if [ "$provider" = lua ]; then
        ${pkgs.hyprland}/bin/hyprctl eval \
          "hl.dispatch(hl.dsp.dpms({ action = \"$action\", monitor = \"$output\" }))" \
          >/dev/null || failed=1
      else
        ${pkgs.hyprland}/bin/hyprctl dispatch dpms "$state" "$output" \
          >/dev/null || failed=1
      fi

      # Each output's fade ends in a separate DRM commit. Do not let two
      # connectors finish together: the second commit can otherwise collide
      # with the first connector's pending page flip and be rejected.
      ${pkgs.coreutils}/bin/sleep 0.5

      # hyprctl reports command acceptance before the asynchronous DRM commit
      # has necessarily succeeded. Treat the connector's resulting state as
      # the contract so the caller can retain recovery state and retry.
      output_matches "$output" || failed=1
    }

    if [ "$state" = off ]; then
      # Reverse the compositor's output order while blanking. Waking uses the
      # normal order, so the two transitions cannot repeatedly favor the same
      # connector when the DRM backend is busy.
      for ((i = ''${#outputs[@]} - 1; i >= 0; i--)); do
        dispatch_output "''${outputs[i]}"
      done
    else
      for output in "''${outputs[@]}"; do
        dispatch_output "$output"
      done
    fi

    for output in "''${outputs[@]}"; do
      output_matches "$output" || failed=1
    done
    exit "$failed"
  '';

  lockDpmsScript = pkgs.writeShellScript "hyprland-lock-dpms" ''
    set -eu

    state="''${1:?expected on or off}"
    desired_state="''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-state"
    targets_file="''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-outputs"
    wake_file="''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-woke"
    case "$state" in
      off)
        # Keep the outputs captured before the first sleep. A deeply sleeping
        # DisplayPort sink may disappear from later compositor queries, but it
        # still has to be part of the next wake attempt.
        if [ ! -s "$targets_file" ]; then
          ${pkgs.hyprland}/bin/hyprctl monitors all -j \
            | ${pkgs.jq}/bin/jq -r '.[] | select(.disabled != true) | .name' \
            >"$targets_file"
        fi
        echo off >"$desired_state"
        exec ${dpmsScript} off
        ;;
      on)
        echo on >"$desired_state"
        : >"$wake_file"
        # Do not clear the requested state here. The DRM commit can report On
        # briefly and regress later; the lock-lifetime guardian owns stable
        # convergence and the eventual cleanup.
        exec ${dpmsScript} on
        ;;
      *) exit 2 ;;
    esac
  '';

  dpmsGuardianScript = pkgs.writeShellScript "hyprland-lock-dpms-guardian" ''
    set -u

    desired_state="''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-state"
    targets_file="''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-outputs"
    wake_file="''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-woke"
    stable_unlocked_samples=0
    last_state=""

    reapply_desired_state() {
      if [ ! -e "$desired_state" ]; then
        compositor_locked="$(${pkgs.hyprland}/bin/hyprctl -j locked 2>/dev/null \
          | ${pkgs.jq}/bin/jq -r '.locked // true' 2>/dev/null || printf 'true\n')"
        [ "$compositor_locked" = true ] && return 0
        return 1
      fi
      state="$(${pkgs.coreutils}/bin/head -n 1 "$desired_state" 2>/dev/null)" || return 0

      case "$state" in
        off | on) ;;
        *) return 0 ;;
      esac

      if [ "$state" != "$last_state" ]; then
        stable_unlocked_samples=0
        last_state="$state"
      fi

      if ! ${dpmsScript} "$state" >/dev/null 2>&1; then
        stable_unlocked_samples=0
        return 0
      fi

      if [ "$state" = off ]; then
        stable_unlocked_samples=0
        return 0
      fi

      compositor_locked="$(${pkgs.hyprland}/bin/hyprctl -j locked 2>/dev/null \
        | ${pkgs.jq}/bin/jq -r '.locked // true' 2>/dev/null || printf 'true\n')"
      if [ "$compositor_locked" = true ]; then
        # Stay alive for the whole lock. A connector can regress several
        # seconds after its first successful-looking atomic commit.
        stable_unlocked_samples=0
        return 0
      fi

      stable_unlocked_samples=$((stable_unlocked_samples + 1))
      if ((stable_unlocked_samples >= 5)); then
        ${pkgs.coreutils}/bin/rm -f "$desired_state" "$targets_file" "$wake_file"
        return 1
      fi

      return 0
    }

    while true; do
      ${pkgs.coreutils}/bin/sleep 1
      reapply_desired_state || exit 0
    done
  '';

  mkDisplayIdleConfig = delay:
    pkgs.writeTextDir "hypr/hypridle.conf" ''
      general {
        ignore_dbus_inhibit = true
      }

      listener {
        timeout = ${toString delay}
        ignore_inhibit = true
        on-timeout = ${lockDpmsScript} off
        on-resume = ${lockDpmsScript} on
      }
    '';
  displayIdleConfig = mkDisplayIdleConfig cfg.displayOffDelay;
  immediateDisplayIdleConfig = mkDisplayIdleConfig 1;

  lockScript = pkgs.writeShellScriptBin "lock-screen" ''
    set -u

    case "''${1:-}" in
      "")
        display_off_immediately=false
        hyprlock_args=()
        ;;
      --display-off-immediately)
        shift
        display_off_immediately=true
        hyprlock_args=(--immediate-render --no-fade-in)
        ;;
      *)
        echo "Usage: lock-screen [--display-off-immediately]" >&2
        exit 2
        ;;
    esac
    if (($# != 0)); then
      echo "Usage: lock-screen [--display-off-immediately]" >&2
      exit 2
    fi

    desired_state="''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-state"
    targets_file="''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-outputs"
    wake_file="''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-woke"
    exec 9>"''${XDG_RUNTIME_DIR:?}/lock-screen.lock"
    ${pkgs.util-linux}/bin/flock -n 9 || exit 0
    ${pkgs.coreutils}/bin/rm -f "$desired_state" "$targets_file" "$wake_file"

    HYPRLOCK="${cfg.package}/bin/hyprlock"
    if ! ${boolToString cfg.turnOffDisplaysOnLock}; then
      exec "$HYPRLOCK" "''${hyprlock_args[@]}"
    fi

    lock_runtime_dir="$(${pkgs.coreutils}/bin/mktemp \
      -d "''${XDG_RUNTIME_DIR:?}/lock-screen.XXXXXX")"
    lock_log="$lock_runtime_dir/hyprlock.log"
    idle_pid=""
    guardian_pid=""
    companions_cleaned=false

    run_display_idle_daemon() {
      if ! $display_off_immediately; then
        exec ${pkgs.hypridle}/bin/hypridle \
          --quiet \
          --config ${displayIdleConfig}/hypr/hypridle.conf
      fi

      initial_idle_pid=""
      stop_initial_idle() {
        if [ -n "$initial_idle_pid" ]; then
          kill "$initial_idle_pid" 2>/dev/null || true
          wait "$initial_idle_pid" 2>/dev/null || true
          initial_idle_pid=""
        fi
      }
      trap stop_initial_idle EXIT
      trap 'stop_initial_idle; exit 0' TERM INT

      ${pkgs.hypridle}/bin/hypridle \
        --quiet \
        --config ${immediateDisplayIdleConfig}/hypr/hypridle.conf &
      initial_idle_pid="$!"

      while kill -0 "$initial_idle_pid" 2>/dev/null; do
        if [ -e "$wake_file" ]; then
          stop_initial_idle
          ${pkgs.coreutils}/bin/rm -f "$wake_file"
          trap - EXIT TERM INT

          # Super+Shift+Q blanks immediately only for the first sleep. Once
          # input wakes the lock screen, use the normal grace period so both
          # connectors remain awake while the password is entered.
          exec ${pkgs.hypridle}/bin/hypridle \
            --quiet \
            --config ${displayIdleConfig}/hypr/hypridle.conf
        fi
        ${pkgs.coreutils}/bin/sleep 0.1
      done

      wait "$initial_idle_pid" 2>/dev/null || true
    }

    cleanup_companions() {
      $companions_cleaned && return 0
      companions_cleaned=true

      if [ -n "$idle_pid" ]; then
        kill "$idle_pid" 2>/dev/null || true
        wait "$idle_pid" 2>/dev/null || true
        idle_pid=""
      fi

      # Only issue a wake transition if the lock-owned idle daemon actually
      # requested DPMS-off. A redundant DPMS-on sequence also creates atomic
      # commits and can aggravate the same multi-output driver race.
      if [ -e "$desired_state" ]; then
        echo on >"$desired_state"
        : >"$wake_file"
        ${dpmsScript} on >/dev/null 2>&1 || true

        # Validate wake independently of the background guardian before the
        # lock process exits. Background children can receive SIGHUP with an
        # interactive caller, and the cleanup contract must not depend on one
        # surviving long enough to remove its runtime files.
        stable_samples=0
        for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
          if ${dpmsScript} on >/dev/null 2>&1; then
            stable_samples=$((stable_samples + 1))
            if ((stable_samples >= 5)); then
              ${pkgs.coreutils}/bin/rm -f "$desired_state" "$targets_file" "$wake_file"
              break
            fi
          else
            stable_samples=0
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done
      fi

      if [ -n "$guardian_pid" ] && [ ! -e "$desired_state" ]; then
        kill "$guardian_pid" 2>/dev/null || true
        wait "$guardian_pid" 2>/dev/null || true
        guardian_pid=""
      elif [ -n "$guardian_pid" ]; then
        # A target is still unavailable after the bounded synchronous retry.
        # Leave the guardian alive for normal compositor-launched locks; the
        # next lock invocation also clears any stale state defensively.
        guardian_pid=""
      fi
    }

    cleanup() {
      cleanup_companions
      ${pkgs.coreutils}/bin/rm -f "$lock_log"
      ${pkgs.coreutils}/bin/rmdir "$lock_runtime_dir" 2>/dev/null || true
    }
    trap cleanup EXIT

    wait_for_lock_ready() {
      lock_pid="$1"

      # Hyprlock emits this only after receiving ext_session_lock_v1.locked.
      # Hyprland sends that event after it has rendered a lock frame on every
      # enabled, awake output. Do not let DPMS race lock-surface creation.
      for _ in $(${pkgs.coreutils}/bin/seq 1 200); do
        if ${pkgs.gnugrep}/bin/grep -Fq "onLockLocked called" "$lock_log"; then
          return 0
        fi
        if ! kill -0 "$lock_pid" 2>/dev/null; then
          return 1
        fi
        ${pkgs.coreutils}/bin/sleep 0.05
      done

      echo "lock-screen: Hyprlock did not establish the session lock within 10 seconds; leaving displays on" >&2
      return 1
    }

    run_locker() {
      companions_cleaned=false
      : >"$lock_log"
      "$HYPRLOCK" "''${hyprlock_args[@]}" \
        > >(${pkgs.coreutils}/bin/tee "$lock_log") 2>&1 &
      lock_pid="$!"

      if wait_for_lock_ready "$lock_pid"; then
        # The locked event follows the first frame submission, not necessarily
        # its final page flip. Let that commit settle before arming DPMS.
        ${pkgs.coreutils}/bin/sleep 0.5

        run_display_idle_daemon &
        idle_pid="$!"
        ${dpmsGuardianScript} >/dev/null 2>&1 &
        guardian_pid="$!"

        # A missing or invalid private config must not silently leave a locked
        # OLED displaying a static image. Hyprlock remains authoritative even
        # if a DPMS companion fails, but make that failure visible.
        ${pkgs.coreutils}/bin/sleep 0.1
        if ! kill -0 "$idle_pid" 2>/dev/null; then
          wait "$idle_pid" || true
          idle_pid=""
          echo "lock-screen: lock-owned hypridle failed to start" >&2
        fi
        if ! kill -0 "$guardian_pid" 2>/dev/null; then
          wait "$guardian_pid" || true
          guardian_pid=""
          echo "lock-screen: DPMS connector guardian failed to start" >&2
        fi
      else
        echo "lock-screen: Hyprlock exited or stalled before its lock surfaces were ready; leaving displays on" >&2
      fi

      wait "$lock_pid"
      lock_status="$?"
      cleanup_companions
      return "$lock_status"
    }

    # A successful authentication clears Hyprland's lock state before
    # Hyprlock exits. If the client exits while Hyprland remains locked, the
    # lock client crashed; retry once via allow_session_lock_restore instead of
    # leaving the compositor on its lock-dead screen.
    for attempt in 1 2; do
      if run_locker; then
        lock_status=0
      else
        lock_status="$?"
      fi

      compositor_locked="$(${pkgs.hyprland}/bin/hyprctl -j locked 2>/dev/null \
        | ${pkgs.jq}/bin/jq -r '.locked // false' 2>/dev/null || true)"
      if [ "$compositor_locked" != true ]; then
        exit "$lock_status"
      fi

      if [ "$attempt" -eq 2 ]; then
        echo "lock-screen: Hyprlock crashed again while the compositor remained locked" >&2
        exit 1
      fi

      echo "lock-screen: Hyprlock exited while the compositor remained locked; restoring it once" >&2
      ${pkgs.coreutils}/bin/sleep 0.5
    done
  '';

  wallpaperPath =
    if cfg.wallpaper.useStandardDir
    then
      if cfg.wallpaper.randomFromDir
      then "$(${pkgs.findutils}/bin/find ${cfg.wallpaper.standardDir} -type f \\( -name '*.jpg' -o -name '*.jpeg' -o -name '*.png' \\) | ${pkgs.coreutils}/bin/shuf -n 1)"
      else "${cfg.wallpaper.standardDir}/${cfg.wallpaper.filename}"
    else if cfg.wallpaper.path == "screenshot"
    then "screenshot"
    else cfg.wallpaper.path;

  substituteConfig = text: let
    colorPlaceholders = [
      "@base00@"
      "@base01@"
      "@base02@"
      "@base03@"
      "@base04@"
      "@base05@"
      "@base06@"
      "@base07@"
      "@base08@"
      "@base09@"
      "@base0a@"
      "@base0b@"
      "@base0c@"
      "@base0d@"
      "@base0e@"
      "@base0f@"
    ];
    colorValues = [
      colors.base00
      colors.base01
      colors.base02
      colors.base03
      colors.base04
      colors.base05
      colors.base06
      colors.base07
      colors.base08
      colors.base09
      colors.base0A
      colors.base0B
      colors.base0C
      colors.base0D
      colors.base0E
      colors.base0F
    ];
    configPlaceholders = [
      "@WALLPAPER_PATH@"
      "@WALLPAPER_COLOR@"
      "@BLUR_PASSES@"
      "@BLUR_SIZE@"
      "@USER@"
    ];
    configValues = [
      wallpaperPath
      cfg.wallpaper.color
      (toString cfg.wallpaper.blur.passes)
      (toString cfg.wallpaper.blur.size)
      username
    ];
  in
    builtins.replaceStrings (colorPlaceholders ++ configPlaceholders) (colorValues ++ configValues) text;

  processedConfig = substituteConfig (builtins.readFile ./hyprlock.conf.template);
in {
  options.services.hyprlock = with types; {
    enable = mkEnableOption "Hyprlock screen locker";

    package = mkOption {
      type = package;
      default = pkgs.hyprlock;
      description = "The hyprlock package to use";
    };

    turnOffDisplaysOnLock = mkOption {
      type = bool;
      default = false;
      description = "Whether to turn off displays after manual locking";
    };

    displayOffDelay = mkOption {
      type = int;
      default = 10;
      description = "Seconds to wait before turning off displays after manual locking";
    };

    lockCommand = mkOption {
      type = str;
      default = "${lockScript}/bin/lock-screen";
      description = "Command to run to lock the screen";
    };

    wallpaper = {
      path = mkOption {
        type = str;
        default = "screenshot";
        description = "Wallpaper path, or screenshot to use a screenshot of the current desktop";
      };

      useStandardDir = mkOption {
        type = bool;
        default = false;
        description = "Whether to use the standard wallpapers directory";
      };

      standardDir = mkOption {
        type = str;
        default = "${config.home.homeDirectory}/.config/wallpapers";
        description = "Path to the standard wallpapers directory";
      };

      filename = mkOption {
        type = str;
        default = "lock.jpg";
        description = "Wallpaper filename in the standard directory";
      };

      randomFromDir = mkOption {
        type = bool;
        default = false;
        description = "Whether to use a random wallpaper from the standard directory";
      };

      color = mkOption {
        type = str;
        default = "rgb(${colors.base00})";
        description = "Background color to use behind the wallpaper";
      };

      blur = {
        size = mkOption {
          type = int;
          default = 7;
          description = "Blur size for the background";
        };

        passes = mkOption {
          type = int;
          default = 3;
          description = "Number of blur passes to apply";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    home.packages = [lockScript cfg.package];
    xdg.configFile."hypr/hyprlock.conf".text = processedConfig;
    home.sessionVariables.HYPRLOCK_SCRIPT = "${lockScript}/bin/lock-screen";
  };
}
