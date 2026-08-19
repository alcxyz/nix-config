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
    exec 8>"$runtime_dir/hyprland-dpms.lock"
    ${pkgs.util-linux}/bin/flock 8

    case "$state" in
      on) action=enable ;;
      off) action=disable ;;
      *) exit 2 ;;
    esac

    provider="$(${pkgs.hyprland}/bin/hyprctl status -j 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.configProvider // empty')"
    mapfile -t outputs < <(
      ${pkgs.hyprland}/bin/hyprctl monitors all -j \
        | ${pkgs.jq}/bin/jq -r '.[] | select(.disabled != true) | .name'
    )
    ((''${#outputs[@]} > 0)) || {
      echo "hyprland-dpms: no enabled outputs found" >&2
      exit 1
    }

    failed=0
    dispatch_output() {
      output="$1"
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
    exit "$failed"
  '';

  lockDpmsScript = pkgs.writeShellScript "hyprland-lock-dpms" ''
    set -eu

    state="''${1:?expected on or off}"
    desired_state="''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-state"
    case "$state" in
      off)
        echo off >"$desired_state"
        exec ${dpmsScript} off
        ;;
      on)
        echo on >"$desired_state"
        if ${dpmsScript} on; then
          ${pkgs.coreutils}/bin/rm -f "$desired_state"
        else
          exit 1
        fi
        ;;
      *) exit 2 ;;
    esac
  '';

  dpmsGuardianScript = pkgs.writeShellScript "hyprland-lock-dpms-guardian" ''
    set -u

    desired_state="''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-state"

    reapply_desired_state() {
      [ -e "$desired_state" ] || return 0
      state="$(${pkgs.coreutils}/bin/head -n 1 "$desired_state" 2>/dev/null)" || return 0

      case "$state" in
        off) expected=false ;;
        on) expected=true ;;
        *) return 0 ;;
      esac

      ${pkgs.hyprland}/bin/hyprctl monitors all -j 2>/dev/null \
        | ${pkgs.jq}/bin/jq -e --argjson expected "$expected" \
          'any(.[]; (.disabled != true) and (.dpmsStatus != $expected))' \
          >/dev/null || return 0

      ${dpmsScript} "$state" >/dev/null 2>&1 || true
    }

    while true; do
      ${pkgs.coreutils}/bin/sleep 1
      reapply_desired_state
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
        display_idle_config=${displayIdleConfig}/hypr/hypridle.conf
        hyprlock_args=()
        ;;
      --display-off-immediately)
        shift
        display_idle_config=${immediateDisplayIdleConfig}/hypr/hypridle.conf
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
    exec 9>"''${XDG_RUNTIME_DIR:?}/lock-screen.lock"
    ${pkgs.util-linux}/bin/flock -n 9 || exit 0
    ${pkgs.coreutils}/bin/rm -f "$desired_state"

    HYPRLOCK="${cfg.package}/bin/hyprlock"
    if ! ${boolToString cfg.turnOffDisplaysOnLock}; then
      exec "$HYPRLOCK" "''${hyprlock_args[@]}"
    fi

    lock_runtime_dir="$(${pkgs.coreutils}/bin/mktemp \
      -d "''${XDG_RUNTIME_DIR:?}/lock-screen.XXXXXX")"
    lock_log="$lock_runtime_dir/hyprlock.log"
    idle_pid=""
    guardian_pid=""

    cleanup_companions() {
      if [ -n "$guardian_pid" ]; then
        kill "$guardian_pid" 2>/dev/null || true
        wait "$guardian_pid" 2>/dev/null || true
        guardian_pid=""
      fi
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
        ${dpmsScript} on >/dev/null 2>&1 || true
        ${pkgs.coreutils}/bin/rm -f "$desired_state"
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
      : >"$lock_log"
      "$HYPRLOCK" "''${hyprlock_args[@]}" \
        > >(${pkgs.coreutils}/bin/tee "$lock_log") 2>&1 &
      lock_pid="$!"

      if wait_for_lock_ready "$lock_pid"; then
        # The locked event follows the first frame submission, not necessarily
        # its final page flip. Let that commit settle before arming DPMS.
        ${pkgs.coreutils}/bin/sleep 0.5

        ${pkgs.hypridle}/bin/hypridle \
          --quiet \
          --config "$display_idle_config" &
        idle_pid="$!"
        ${dpmsGuardianScript} &
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
