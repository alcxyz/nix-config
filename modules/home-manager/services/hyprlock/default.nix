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
    # A lock's helpers pass the lock they serve. Once a newer lock owns the
    # state files, exit 3 without touching the outputs it now controls. If
    # the lock's requested state changed since the caller read it, exit 4 and
    # leave the newer request to its own transition.
    owner="''${2:-}"
    runtime_dir="''${XDG_RUNTIME_DIR:?}"
    targets_file="$runtime_dir/hyprlock-dpms-outputs"
    exec 8>"$runtime_dir/hyprland-dpms.lock"
    ${pkgs.util-linux}/bin/flock 8
    if [ -n "$owner" ]; then
      if [ "$(${pkgs.coreutils}/bin/head -n 1 "$runtime_dir/hyprlock-dpms-owner" 2>/dev/null)" != "$owner" ]; then
        exit 3
      fi
      if [ "$(${pkgs.coreutils}/bin/head -n 1 "$runtime_dir/hyprlock-dpms-state" 2>/dev/null)" != "$state" ]; then
        exit 4
      fi
    fi

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
        # An output that was disabled since the lock captured it (remote-desk
        # on) has nothing to wake, and a virtual output that is gone (the
        # remote desk after off) will not come back. A missing physical
        # connector may be a sink in deep sleep and stays a target.
        ${pkgs.jq}/bin/jq -e --arg output "$output" \
          '(map(select(.name == $output)) | first) as $m
           | if $m == null then ($output | startswith("HEADLESS-"))
             else ($m.disabled == true or $m.dpmsStatus == true) end' \
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
    # The lock whose Hypridle runs this callback. Hypridle starts callbacks
    # asynchronously, so one can still run after that lock's cleanup has
    # retired its Hypridle (requested the final wake), or after a newer lock
    # owns the state files; it must then leave them alone.
    owner="''${HYPRLOCK_DPMS_OWNER:-}"
    case "$state" in
      off | on) ;;
      *) exit 2 ;;
    esac

    (
      exec 7>"''${XDG_RUNTIME_DIR:?}/hyprland-dpms.lock"
      ${pkgs.util-linux}/bin/flock 7
      if [ -n "$owner" ]; then
        if [ "$(${pkgs.coreutils}/bin/head -n 1 "''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-owner" 2>/dev/null)" != "$owner" ] \
          || [ ! -d "$owner" ] || [ -e "$owner/dpms-retired" ]; then
          exit 3
        fi
      fi
      if [ "$state" = off ]; then
        # Keep the outputs captured before earlier sleeps, including one taken
        # over from an earlier lock's unfinished wake. A deeply sleeping
        # DisplayPort sink may disappear from later compositor queries, but it
        # still has to be part of the next wake attempt. Add the outputs
        # enabled now, such as one connected or re-enabled since.
        {
          ${pkgs.coreutils}/bin/cat "$targets_file" 2>/dev/null || true
          ${pkgs.hyprland}/bin/hyprctl monitors all -j \
            | ${pkgs.jq}/bin/jq -r '.[] | select(.disabled != true) | .name'
        } | ${pkgs.gawk}/bin/awk 'NF && !seen[$0]++' >"$targets_file.new" || exit 1
        ${pkgs.coreutils}/bin/mv -f "$targets_file.new" "$targets_file" || exit 1
        echo off >"$desired_state" || exit 1
      else
        echo on >"$desired_state" || exit 1
        : >"$wake_file" || exit 1
        # Do not clear the requested state here. The DRM commit can report On
        # briefly and regress later; the lock-lifetime guardian owns stable
        # convergence and the eventual cleanup.
      fi
    ) || {
      status="$?"
      ((status == 3)) && exit 0
      exit "$status"
    }

    exec ${dpmsScript} "$state" "$owner"
  '';

  dpmsGuardianScript = pkgs.writeShellScript "hyprland-lock-dpms-guardian" ''
    set -u

    # The lock-screen run this guardian serves; a newer lock replaces it.
    owner="''${1:?expected the owning lock}"
    owner_file="''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-owner"
    desired_state="''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-state"
    targets_file="''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-outputs"
    wake_file="''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-woke"
    stable_unlocked_samples=0
    unlocked_samples=0
    last_state=""

    # Remove the state files only while this guardian still owns them. A new
    # lock claims them under the same mutex, so a guardian finishing its last
    # wake cannot remove the files of a lock that started meanwhile.
    release_state() {
      (
        exec 7>"''${XDG_RUNTIME_DIR:?}/hyprland-dpms.lock"
        ${pkgs.util-linux}/bin/flock 7
        [ "$(${pkgs.coreutils}/bin/head -n 1 "$owner_file" 2>/dev/null)" = "$owner" ] || exit 0
        ${pkgs.coreutils}/bin/rm -f "$desired_state" "$targets_file" "$wake_file"
      )
    }

    reapply_desired_state() {
      # The state files belong to a newer lock, whose own guardian applies
      # them.
      [ "$(${pkgs.coreutils}/bin/head -n 1 "$owner_file" 2>/dev/null)" = "$owner" ] || return 1

      # Only an explicit false is unlocked; jq's `//` would also replace a
      # false, and an unreadable answer counts as locked.
      compositor_locked="$(${pkgs.hyprland}/bin/hyprctl -j locked 2>/dev/null \
        | ${pkgs.jq}/bin/jq -r '.locked' 2>/dev/null)"
      [ "$compositor_locked" = false ] || compositor_locked=true
      if [ ! -e "$desired_state" ]; then
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

      if [ "$compositor_locked" = true ]; then
        unlocked_samples=0
      else
        unlocked_samples=$((unlocked_samples + 1))
        # Waking a connector that regresses settles within seconds; one that
        # never converges must not keep the guardian alive for good.
        if ((unlocked_samples >= 120)); then
          release_state
          return 1
        fi
      fi

      ${dpmsScript} "$state" "$owner" >/dev/null 2>&1
      dpms_status="$?"
      if ((dpms_status == 3)); then
        return 1
      elif ((dpms_status != 0)); then
        stable_unlocked_samples=0
        return 0
      fi

      if [ "$state" = off ] || [ "$compositor_locked" = true ]; then
        # Stay alive for the whole lock. A connector can regress several
        # seconds after its first successful-looking atomic commit.
        stable_unlocked_samples=0
        return 0
      fi

      stable_unlocked_samples=$((stable_unlocked_samples + 1))
      if ((stable_unlocked_samples >= 5)); then
        release_state
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

    HYPRLOCK="${cfg.package}/bin/hyprlock"
    if ! ${boolToString cfg.turnOffDisplaysOnLock}; then
      exec "$HYPRLOCK" "''${hyprlock_args[@]}"
    fi

    lock_runtime_dir="$(${pkgs.coreutils}/bin/mktemp \
      -d "''${XDG_RUNTIME_DIR:?}/lock-screen.XXXXXX")"
    # Guardians left by earlier locks (one whose outputs never woke) stop
    # once this lock owns the state files. Claim them under the DPMS mutex,
    # which a guardian holds while it removes them; a DPMS transition holds
    # it for a few seconds at most. If it stays busy, still lock, but start
    # no display companions and leave the displays on.
    # An earlier lock still waking its outputs (its unlock released the
    # guard while a connector had not settled) stops once this lock owns the
    # state. Take that wake over, as if this lock had woken them itself: keep
    # the requested on and its targets, so this lock's guardian and cleanup
    # finish it. Only the wake marker goes, since it would end an immediate
    # blank.
    if (
      exec 7>"''${XDG_RUNTIME_DIR:?}/hyprland-dpms.lock"
      ${pkgs.util-linux}/bin/flock -w 10 7 || exit 1
      if [ "$(${pkgs.coreutils}/bin/head -n 1 "$desired_state" 2>/dev/null)" = on ]; then
        ${pkgs.coreutils}/bin/rm -f "$wake_file"
      else
        ${pkgs.coreutils}/bin/rm -f "$desired_state" "$targets_file" "$wake_file"
      fi
      printf '%s\n' "$lock_runtime_dir" >"''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-owner"
    ) 9>&-; then
      dpms_owned=true
    else
      dpms_owned=false
      echo "lock-screen: the display mutex stayed busy; locking with displays left on" >&2
    fi
    owner_file="''${XDG_RUNTIME_DIR:?}/hyprlock-dpms-owner"
    lock_log="$lock_runtime_dir/hyprlock.log"
    retired_marker="$lock_runtime_dir/dpms-retired"
    idle_pid=""
    guardian_pid=""
    companions_cleaned=false
    lock_guard_released=false

    owns_dpms_state() {
      [ "$(${pkgs.coreutils}/bin/head -n 1 "$owner_file" 2>/dev/null)" = "$lock_runtime_dir" ]
    }

    # Remove the state files under the DPMS mutex, unless a newer lock owns
    # them by now.
    release_dpms_state() {
      (
        exec 7>"''${XDG_RUNTIME_DIR:?}/hyprland-dpms.lock"
        ${pkgs.util-linux}/bin/flock 7
        owns_dpms_state || exit 0
        ${pkgs.coreutils}/bin/rm -f "$desired_state" "$targets_file" "$wake_file"
      ) 9>&-
    }

    run_display_idle_daemon() {
      # Hypridle's callbacks inherit this and act only while this lock owns
      # the display state.
      export HYPRLOCK_DPMS_OWNER="$lock_runtime_dir"

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
      # commits and can aggravate the same multi-output driver race. Request
      # it before releasing the guard below, so a lock started after the
      # release finds the wake to take over. In the same hold of the mutex,
      # retire this lock's Hypridle: a callback it started before being
      # killed must not request off after this final wake.
      wake_requested=false
      if $dpms_owned && (
        exec 7>"''${XDG_RUNTIME_DIR:?}/hyprland-dpms.lock"
        ${pkgs.util-linux}/bin/flock 7
        owns_dpms_state || exit 1
        : >"$retired_marker"
        [ -e "$desired_state" ] || exit 1
        echo on >"$desired_state"
        : >"$wake_file"
      ) 9>&-; then
        wake_requested=true
      fi

      # Once the session is unlocked, release the single-lock guard before
      # waking the displays. A target that cannot wake (a monitor switched
      # off at its button leaves the cable) keeps the retries below going
      # for 30 seconds, and a lock started meanwhile must not be dropped. The
      # new lock takes the display state over and the retries stop.
      compositor_locked="$(${pkgs.hyprland}/bin/hyprctl -j locked 2>/dev/null \
        | ${pkgs.jq}/bin/jq -r '.locked' 2>/dev/null)"
      if [ "$compositor_locked" = false ]; then
        exec 9>&-
        lock_guard_released=true
      fi

      if $wake_requested; then
        # Validate wake independently of the background guardian before the
        # lock process exits. Background children can receive SIGHUP with an
        # interactive caller, and the cleanup contract must not depend on one
        # surviving long enough to remove its runtime files.
        stable_samples=0
        for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
          ${dpmsScript} on "$lock_runtime_dir" >/dev/null 2>&1
          dpms_status="$?"
          if ((dpms_status == 3)); then
            break
          elif ((dpms_status == 4)) && [ ! -e "$desired_state" ]; then
            # The guardian saw the wake settle first and removed the request.
            break
          elif ((dpms_status == 0)); then
            stable_samples=$((stable_samples + 1))
            if ((stable_samples >= 5)); then
              release_dpms_state
              break
            fi
          else
            stable_samples=0
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done
      fi

      if [ -n "$guardian_pid" ] && { ! owns_dpms_state || [ ! -e "$desired_state" ]; }; then
        kill "$guardian_pid" 2>/dev/null || true
        wait "$guardian_pid" 2>/dev/null || true
        guardian_pid=""
      elif [ -n "$guardian_pid" ]; then
        # A target is still unavailable after the bounded synchronous retry.
        # Leave the guardian alive for normal compositor-launched locks. A
        # newer lock stops it and takes over the unfinished wake.
        guardian_pid=""
      fi
    }

    cleanup() {
      cleanup_companions
      ${pkgs.coreutils}/bin/rm -f "$lock_log"
      # A late Hypridle callback checks the retirement marker and this
      # directory under the DPMS mutex, so remove both in one hold of it:
      # the callback then sees either the marker or no directory. If the
      # mutex stays busy, leave them; a retired directory is harmless.
      (
        exec 7>"''${XDG_RUNTIME_DIR:?}/hyprland-dpms.lock"
        ${pkgs.util-linux}/bin/flock -w 10 7 || exit 0
        ${pkgs.coreutils}/bin/rm -f "$retired_marker"
        ${pkgs.coreutils}/bin/rmdir "$lock_runtime_dir" 2>/dev/null \
          || : >"$retired_marker"
      ) 9>&-
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
      # A restored lock starts a new Hypridle for the same owner.
      ${pkgs.coreutils}/bin/rm -f "$retired_marker"
      : >"$lock_log"
      "$HYPRLOCK" "''${hyprlock_args[@]}" \
        > >(${pkgs.coreutils}/bin/tee "$lock_log") 2>&1 &
      lock_pid="$!"

      if ! $dpms_owned; then
        : # Locked without the display companions; see the claim above.
      elif wait_for_lock_ready "$lock_pid"; then
        # The locked event follows the first frame submission, not necessarily
        # its final page flip. Let that commit settle before arming DPMS.
        ${pkgs.coreutils}/bin/sleep 0.5

        run_display_idle_daemon 9>&- &
        idle_pid="$!"
        ${dpmsGuardianScript} "$lock_runtime_dir" 9>&- >/dev/null 2>&1 &
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

      # The guard went with the unlock, so a locked compositor now belongs
      # to a newer lock rather than to a crashed Hyprlock.
      if $lock_guard_released; then
        exit "$lock_status"
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
