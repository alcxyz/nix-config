# users/alc/linux/xyz.nix
{
  config,
  pkgs,
  lib,
  inputs,
  configDir,
  hostRole,
  ...
}: let
  pkgsets = import "${configDir}/modules/shared/pkgsets.nix" {
    inherit pkgs inputs;
  };
  kdeConnectScrollThrottle =
    pkgs.callPackage "${configDir}/modules/nixos/services/kdeconnect-scroll-throttle"
    {};
  gamingWindowMatchers = [
    {
      classRegex = "^steam_app_default$";
      titleRegex = "^Heroes of the Storm$";
    }
  ];
  gameWindowGeometryPolicies = map (matcher:
    matcher
    // {
      restoreMonitor = "DP-1";
    })
  gamingWindowMatchers;
  protonGe10_4 =
    (pkgs.proton-ge-bin.overrideAttrs (finalAttrs: _: {
      version = "GE-Proton10-4";
      src = pkgs.fetchzip {
        url = "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${finalAttrs.version}/${finalAttrs.version}.tar.gz";
        hash = "sha256-Si/CQ2PINfhmsC+uW3iFBUoSczZdkqwCZ8FAFuipu68=";
      };
    })).steamcompattool;
  battleNetPrefix = "/ext4/games/Heroic/Prefixes/default/Battle.net";
  battleNetEnvironment = {
    DRI_PRIME = "1";
    DXVK_CONFIG = "dxgi.maxFrameRate = 120";
    DXVK_FRAME_RATE = "120";
    TZ = "Europe/Oslo";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    __NV_PRIME_RENDER_OFFLOAD = "1";
  };
  battleNetIcon = pkgs.fetchurl {
    name = "battle-net.png";
    url = "https://lutris.net/games/icon/battlenet.png";
    hash = "sha256-Otx9a99ZJx++nqBj/5ljwALoFFoxRPXao3zFaZpGyao=";
  };
  heroesProfileIcon = pkgs.fetchurl {
    name = "heroes-profile.png";
    url = "https://raw.githubusercontent.com/Heroes-Profile/HeroesProfile.Uploader/f73fa675d197875237a8973c2f2a899b293b6f09/Heroesprofile.Uploader.Windows/Resources/heroesprofilelogo.png";
    hash = "sha256-T1XhH5DmAAFvFJhD3qbwaqXIvHczbt77Wi7kPZuuo+0=";
  };
  mailWorkspaceScript = ''
    workspace=9
    clients="$(hyprctl clients -j 2>/dev/null)"
    jq -e 'type == "array"' <<<"$clients" >/dev/null
    provider="$(hyprctl status -j | jq -r '.configProvider // empty')"

    focus_workspace() {
      if [[ "$provider" == lua ]]; then
        hyprctl eval \
          "hl.dispatch(hl.dsp.focus({ workspace = $workspace }))" \
          >/dev/null
      else
        hyprctl dispatch workspace "$workspace" >/dev/null
      fi
    }

    launch_mail() {
      if [[ "$provider" == lua ]]; then
        hyprctl eval \
          "hl.dispatch(hl.dsp.exec_cmd(\"thunderbird\", { workspace = \"$workspace silent\" }))" \
          >/dev/null
      else
        hyprctl dispatch exec "[workspace $workspace silent] thunderbird" \
          >/dev/null
      fi
    }

    move_window() {
      local address="$1"
      if [[ "$provider" == lua ]]; then
        hyprctl eval \
          "hl.dispatch(hl.dsp.window.move({ workspace = $workspace, window = \"address:$address\", follow = false }))" \
          >/dev/null
      else
        hyprctl dispatch movetoworkspacesilent "$workspace,address:$address" \
          >/dev/null
      fi
    }

    focus_window() {
      local address="$1"
      if [[ "$provider" == lua ]]; then
        hyprctl eval \
          "hl.dispatch(hl.dsp.focus({ window = \"address:$address\" }))" \
          >/dev/null
      else
        hyprctl dispatch focuswindow "address:$address" >/dev/null
      fi
    }

    mapfile -t addresses < <(
      jq -r '
        .[]
        | select(
            .mapped == true
            and (.class == "thunderbird" or .initialClass == "thunderbird")
            and (.address | test("^0x[0-9a-fA-F]+$"))
          )
        | .address
      ' <<<"$clients"
    )

    if ((''${#addresses[@]} == 0)); then
      launch_mail
      focus_workspace
      exit 0
    fi

    for address in "''${addresses[@]}"; do
      move_window "$address" || true
    done
    focus_workspace
    focus_window "''${addresses[0]}" || true
  '';
  mailWorkspace = pkgs.writeShellApplication {
    name = "hyprland-mail-workspace";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.jq
      pkgs.thunderbird
    ];
    text = mailWorkspaceScript;
  };
  closeActiveWindowScript = ''
    active_window="$(hyprctl activewindow -j 2>/dev/null || true)"
    active_class="$(jq -r '.class // empty' <<<"$active_window" 2>/dev/null || true)"
    active_title="$(jq -r '.title // empty' <<<"$active_window" 2>/dev/null || true)"
    active_pid="$(jq -r '.pid // 0' <<<"$active_window" 2>/dev/null || true)"

    if [[ "$active_class" == steam_app_default && "$active_title" == Battle.net ]] \
      && [[ "$active_pid" =~ ^[1-9][0-9]*$ ]] \
      && [[ -r "/proc/$active_pid/cgroup" ]]; then
      cgroup="$(awk -F: '$1 == "0" { print $3; exit }' "/proc/$active_pid/cgroup")"
      clients="$(hyprctl clients -j 2>/dev/null || true)"

      if [[ "$cgroup" == */umu-app-battle-net.service ]] \
        && jq -e 'type == "array"' <<<"$clients" >/dev/null 2>&1 \
        && ! jq -e 'any(.[]; .class == "steam_app_default" and .title == "Heroes of the Storm")' \
          <<<"$clients" >/dev/null; then
        # Closing Battle.net's window can leave its Wine runtime behind.
        # Stop only the direct launcher's owning cgroup, and never while a
        # Heroes window is present. All uncertain cases use normal close.
        exec systemctl --user --no-block stop umu-app-battle-net.service
      fi
    fi

    exec hyprctl dispatch killactive
  '';
  closeActiveWindow = pkgs.writeShellApplication {
    name = "hyprland-close-active-window";
    runtimeInputs = [
      pkgs.gawk
      pkgs.hyprland
      pkgs.jq
      pkgs.systemd
    ];
    text = closeActiveWindowScript;
  };
  xwaylandPrimaryOutput = pkgs.writeShellApplication {
    name = "hyprland-xwayland-primary-output";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.socat
      pkgs.xrandr
    ];
    text = ''
      socket="''${XDG_RUNTIME_DIR:?}/hypr/''${HYPRLAND_INSTANCE_SIGNATURE:?}/.socket2.sock"
      repair_requested="''${XDG_RUNTIME_DIR:?}/hyprland-xwayland-primary-output.requested"

      set_primary() {
        stable_samples=0
        for _ in $(seq 1 150); do
          if DISPLAY="''${DISPLAY:-:0}" xrandr --current 2>/dev/null \
            | grep -q '^DP-1 connected primary '; then
            stable_samples=$((stable_samples + 1))
            if ((stable_samples >= 30)); then
              return 0
            fi
          else
            stable_samples=0
            DISPLAY="''${DISPLAY:-:0}" xrandr --output DP-1 --primary \
              >/dev/null 2>&1 || true
          fi
          sleep 0.1
        done

        echo "Failed to mark DP-1 as the XWayland primary output" >&2
        return 1
      }

      ensure_primary() {
        current_outputs="$(DISPLAY="''${DISPLAY:-:0}" xrandr --current 2>/dev/null || true)"
        if grep -q '^DP-1 connected primary ' <<<"$current_outputs"; then
          return 0
        fi
        if ! grep -q '^DP-1 connected ' <<<"$current_outputs"; then
          return 0
        fi
        set_primary
      }

      watch_output_events() {
        while true; do
          while IFS= read -r event; do
            case "$event" in
              monitoradded\>\>* | monitoraddedv2\>\>* | dpms\>\>*)
                : >"$repair_requested"
                ;;
            esac
          done < <(socat -U - UNIX-CONNECT:"$socket" 2>/dev/null)
          sleep 1
        done
      }

      watch_output_events &
      watcher_pid=$!
      trap 'kill "$watcher_pid" 2>/dev/null || true; rm -f "$repair_requested"' EXIT

      : >"$repair_requested"
      next_audit=0
      while true; do
        now=$SECONDS
        if [[ -e "$repair_requested" ]] || ((now >= next_audit)); then
          rm -f "$repair_requested"
          ensure_primary || true
          next_audit=$((now + 30))
        fi
        sleep 1
      done
    '';
  };
  gameWindowGeometryGuard = pkgs.writeShellApplication {
    name = "hyprland-game-window-geometry-guard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
      pkgs.socat
    ];
    text = ''
      policies=${lib.escapeShellArg (builtins.toJSON gameWindowGeometryPolicies)}
      socket="''${XDG_RUNTIME_DIR:?}/hypr/''${HYPRLAND_INSTANCE_SIGNATURE:?}/.socket2.sock"
      repair_requested="''${XDG_RUNTIME_DIR:?}/hyprland-game-window-geometry-guard.requested"
      tolerance=16
      provider="$(hyprctl status -j | jq -r '.configProvider // empty')"

      repair_geometry() {
        monitors_json="$(hyprctl monitors -j 2>/dev/null || true)"
        clients_json="$(hyprctl clients -j 2>/dev/null || true)"
        [[ -n "$monitors_json" && -n "$clients_json" ]] || return 0

        while IFS= read -r client_json; do
          address="$(jq -r '.address' <<<"$client_json")"
          monitor_id="$(jq -r '.monitor' <<<"$client_json")"
          restore_monitor="$(jq -r '._guardRestoreMonitor' <<<"$client_json")"
          monitor_json="$(
            if [[ "$restore_monitor" == null ]]; then
              jq -ce --argjson id "$monitor_id" \
                '.[] | select(.id == $id and .dpmsStatus == true)' \
                <<<"$monitors_json" || true
            else
              jq -ce --arg name "$restore_monitor" \
                '.[] | select(.name == $name and .dpmsStatus == true)' \
                <<<"$monitors_json" || true
            fi
          )"
          [[ -n "$monitor_json" ]] || continue

          read -r x y width height < <(
            jq -r '[.at[0], .at[1], .size[0], .size[1]] | @tsv' \
              <<<"$client_json"
          )
          read -r monitor_x monitor_y monitor_width monitor_height < <(
            jq -r '[.x, .y, .width, .height] | @tsv' <<<"$monitor_json"
          )

          # Do not attempt to contain a deliberately oversized window.
          if ((
            width > monitor_width + (2 * tolerance)
            || height > monitor_height + (2 * tolerance)
          )); then
            continue
          fi

          if ((
            x >= monitor_x - tolerance
            && y >= monitor_y - tolerance
            && x + width <= monitor_x + monitor_width + tolerance
            && y + height <= monitor_y + monitor_height + tolerance
          )); then
            continue
          fi

          target_x=$((monitor_x + ((monitor_width - width) / 2)))
          target_y=$((monitor_y + ((monitor_height - height) / 2)))
          if [[ "$provider" == lua ]]; then
            move_result="$(hyprctl eval \
              "hl.dispatch(hl.dsp.window.move({ x = $target_x, y = $target_y, window = \"address:$address\" }))" \
              2>&1 || true)"
          else
            move_result="$(hyprctl dispatch movewindowpixel \
              "exact $target_x $target_y,address:$address" 2>&1 || true)"
          fi
          if [[ "$move_result" == ok* ]]; then
            echo "Recentered watched window $address on monitor $monitor_id"
          else
            echo "Failed to recenter watched window $address: $move_result" >&2
          fi
        done < <(
          jq -c --argjson policies "$policies" '
            .[] | . as $window |
            ([$policies[] | . as $policy | select(
              (($policy.classRegex == null)
                or (($window.class // "") | test($policy.classRegex)))
              and (($policy.titleRegex == null)
                or (($window.title // "") | test($policy.titleRegex)))
              and (($policy.initialClassRegex == null)
                or (($window.initialClass // "") | test($policy.initialClassRegex)))
              and (($policy.initialTitleRegex == null)
                or (($window.initialTitle // "") | test($policy.initialTitleRegex)))
            )] | first) as $policy |
            select(
              $policy != null
              and .mapped == true
              and .hidden == false
              and .floating == true
              and ((.fullscreen // 0) == 0)
            ) |
            . + { _guardRestoreMonitor: ($policy.restoreMonitor // null) }
          ' <<<"$clients_json"
        )
      }

      watch_geometry_events() {
        while true; do
          while IFS= read -r event; do
            case "$event" in
              monitoradded\>\>* | monitoraddedv2\>\>* \
                | monitorremoved\>\>* | monitorremovedv2\>\>* \
                | dpms\>\>*)
                : >"$repair_requested"
                ;;
            esac
          done < <(socat -U - UNIX-CONNECT:"$socket" 2>/dev/null)
          sleep 1
        done
      }

      watch_geometry_events &
      watcher_pid=$!
      trap 'kill "$watcher_pid" 2>/dev/null || true; rm -f "$repair_requested"' EXIT
      trap 'exit 0' HUP INT TERM

      # Repair a stale window after service/session startup, then stay active
      # briefly after relevant events so delayed XWayland geometry updates are
      # caught without continuously policing intentional window placement.
      : >"$repair_requested"
      active_until=0
      while true; do
        if [[ -e "$repair_requested" ]]; then
          rm -f "$repair_requested"
          active_until=$((SECONDS + 90))
        fi
        if ((SECONDS <= active_until)); then
          repair_geometry
          sleep 1
        else
          sleep 1
        fi
      done
    '';
  };
  droptermToggle = pkgs.writeShellApplication {
    name = "dropterm-toggle";
    runtimeInputs = [
      config.programs.hyprscratch.package
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
      pkgs.netcat-openbsd
      pkgs.systemd
    ];
    text = ''
      target_json="$(hyprctl monitors -j | jq -ce '.[] | select(.focused)')"
      target_workspace="$(jq -r '.activeWorkspace.id' <<<"$target_json")"
      active_is_dropterm="$(
        hyprctl activewindow -j \
          | jq -r '(.initialClass == "dropterm" or .initialTitle == "dropterm") // false'
      )"

      wait_for_toggle() {
        if [[ "$active_is_dropterm" == true ]]; then
          for _ in $(seq 1 80); do
            if ! hyprctl activewindow -j \
              | jq -e '(.initialClass == "dropterm" or .initialTitle == "dropterm") // false' \
                >/dev/null; then
              return 0
            fi
            sleep 0.025
          done
          return 1
        fi

        client_json=""
        for _ in $(seq 1 80); do
          client_json="$(
            hyprctl clients -j \
              | jq -c --argjson workspace "$target_workspace" \
                  '.[] | select(
                    (.initialClass == "dropterm" or .initialTitle == "dropterm")
                    and .workspace.id == $workspace
                  )' \
              | head -n 1
          )"
          [[ -n "$client_json" ]] && return 0
          sleep 0.025
        done
        return 1
      }

      toggle_dropterm() {
        hyprscratch toggle dropterm >/dev/null 2>&1 || return 1
        wait_for_toggle
      }

      if ! toggle_dropterm; then
        # Hyprscratch 0.6.5 can leave its main process alive after its
        # Hyprland event thread loses the compositor socket. Recover the stale
        # daemon once, then retry the user's original toggle.
        systemctl --user restart hyprscratch.service

        socket=/tmp/hyprscratch/hyprscratch.sock
        daemon_ready=false
        for _ in $(seq 1 80); do
          if nc -z -U "$socket" >/dev/null 2>&1; then
            daemon_ready=true
            break
          fi
          sleep 0.025
        done

        if [[ "$daemon_ready" != true ]] || ! toggle_dropterm; then
          echo "dropterm toggle failed after restarting hyprscratch" >&2
          exit 1
        fi
      fi

      # An active dropterm was just hidden; leave its parked geometry alone.
      if [[ "$active_is_dropterm" == true ]]; then
        exit 0
      fi

      address="$(jq -r '.address' <<<"$client_json")"
      read -r target_x target_y target_width target_height < <(
        jq -r '[.x, .y, .width, .height] | @tsv' <<<"$target_json"
      )
      read -r window_width window_height < <(
        jq -r '[.size[0], .size[1]] | @tsv' <<<"$client_json"
      )

      x=$((target_x + (target_width - window_width) / 2))
      y=$((target_y + (target_height - window_height) / 2))
      provider="$(hyprctl status -j | jq -r '.configProvider // empty')"
      if [[ "$provider" == lua ]]; then
        hyprctl eval \
          "hl.dispatch(hl.dsp.window.move({ x = $x, y = $y, window = \"address:$address\" }))" \
          >/dev/null
        hyprctl eval \
          "hl.dispatch(hl.dsp.focus({ window = \"address:$address\" }))" \
          >/dev/null
      else
        hyprctl dispatch movewindowpixel "exact $x $y,address:$address" >/dev/null
        hyprctl dispatch focuswindow "address:$address" >/dev/null
      fi
    '';
  };
  t3codeWebUrl = "https://t3code.alc.xyz";
  t3codeWebLauncher = pkgs.writeShellApplication {
    name = "t3code-web";
    runtimeInputs = [pkgs.xdg-utils];
    text = ''
      exec xdg-open ${lib.escapeShellArg t3codeWebUrl}
    '';
  };
in {
  assertions = let
    legacyBinds = builtins.readFile "${configDir}/users/alc/configs/hypr/binds.conf";
    legacyDwindleBinds = builtins.readFile "${configDir}/users/alc/configs/hypr/binds-dwindle.conf";
    luaBinds = builtins.readFile "${configDir}/users/alc/configs/hypr/binds.lua";
    luaDwindleBinds = builtins.readFile "${configDir}/users/alc/configs/hypr/binds-dwindle.lua";
    luaConfig = builtins.readFile "${configDir}/users/alc/configs/hypr/hyprland.lua";
    luaScrollingBinds = builtins.readFile "${configDir}/users/alc/configs/hypr/binds-scrolling.lua";
    hostLegacyConfig = config.programs.hyprland.managed.extraConfig;
    hostLuaConfig = config.programs.hyprland.managed.extraLuaConfig;
  in [
    {
      assertion =
        lib.hasInfix ''hl.bind("SUPER + SHIFT + ESCAPE", hl.dsp.window.move({ workspace = "special:" }))'' luaBinds
        && !lib.hasInfix ''hl.bind("SUPER + SHIFT + escape", hl.dsp.exit())'' luaBinds
        && lib.hasInfix "bind = SUPER SHIFT, ESCAPE, movetoworkspace, special" legacyBinds
        && !lib.hasInfix "bind = SUPER SHIFT, escape, exit" legacyBinds;
      message = "Super+Shift+Escape must follow a window to the special workspace and must never exit the session.";
    }
    {
      assertion =
        lib.hasInfix ''hl.bind("SUPER + SHIFT + Q", hl.dsp.exec_cmd(lock .. " --display-off-immediately"))'' luaBinds
        && lib.hasInfix "bind = SUPER SHIFT, Q, exec, $lock --display-off-immediately" legacyBinds;
      message = "Super+Shift+Q must lock with immediate display power-off in both Hyprland configs.";
    }
    {
      assertion =
        lib.hasInfix ''hl.bind("XF86ScreenSaver", hl.dsp.exec_cmd(lock))'' luaBinds
        && lib.hasInfix "bind = , XF86ScreenSaver, exec, $lock" legacyBinds;
      message = "The K850 lock-logo key must use the normal lock-screen path in both Hyprland configs.";
    }
    {
      assertion =
        lib.hasInfix ''hl.bind("SUPER + T", hl.dsp.exec_cmd("hyprland-mail-workspace"))'' luaBinds
        && lib.hasInfix "bind = SUPER, T, exec, hyprland-mail-workspace" legacyBinds
        && lib.hasInfix ''workspace=9'' mailWorkspaceScript
        && lib.hasInfix ''.class == "thunderbird" or .initialClass == "thunderbird"'' mailWorkspaceScript
        && lib.hasInfix ''hl.dsp.exec_cmd(\"thunderbird\", { workspace = \"$workspace silent\" })'' mailWorkspaceScript
        && lib.hasInfix ''hyprctl dispatch exec "[workspace $workspace silent] thunderbird"'' mailWorkspaceScript
        && !lib.hasInfix ''SUPER + G'' luaBinds
        && !lib.hasInfix ''SUPER, G'' legacyBinds
        && !lib.hasInfix ''t3code-desktop'' luaBinds
        && !lib.hasInfix ''t3code-desktop'' legacyBinds
        && !lib.hasInfix ''SUPER + M", hl.dsp.exec_cmd("hyprland-mail-workspace")'' luaBinds
        && !lib.hasInfix ''SUPER, M, exec, hyprland-mail-workspace'' legacyBinds
        && lib.hasInfix ''SUPER + M", hl.dsp.layout("focus")'' luaDwindleBinds
        && lib.hasInfix ''SUPER, M, layoutmsg, focus'' legacyDwindleBinds;
      message = "Super+T must normalize Thunderbird onto its unpinned workspace 9 without displacing layout bindings or launching T3 Code.";
    }
    {
      assertion =
        lib.hasInfix ''window.class == "steam_app_default"'' luaBinds
        && lib.hasInfix ''window.title == "Battle.net"'' luaBinds
        && lib.hasInfix ''hl.dsp.exec_cmd("hyprland-close-active-window")'' luaBinds
        && lib.hasInfix "bind = SUPER, W, exec, hyprland-close-active-window" legacyBinds
        && lib.hasInfix ''[[ "$active_class" == steam_app_default && "$active_title" == Battle.net ]]'' closeActiveWindowScript
        && lib.hasInfix ''[[ "$cgroup" == */umu-app-battle-net.service ]]'' closeActiveWindowScript
        && lib.hasInfix ''.title == "Heroes of the Storm"'' closeActiveWindowScript
        && lib.hasInfix ''exec hyprctl dispatch killactive'' closeActiveWindowScript
        && !lib.hasInfix ''hl.bind("SUPER + W", hl.dsp.window.close())'' luaBinds
        && !lib.hasInfix "bind = SUPER, W, killactive," legacyBinds;
      message = "Super+W must preserve normal window closing unless the focused window is exactly Battle.net.";
    }
    {
      assertion =
        lib.hasInfix ''hl.bind("SUPER + CTRL + " .. key, remote_workspace_action(i))'' luaBinds
        && lib.hasInfix ''hl.bind("CTRL + " .. key, fkey_action(i, true))'' luaBinds
        && lib.hasInfix ''monitor:set_workspace({ workspace = workspace })'' luaBinds
        && lib.hasInfix ''restore_focus_after(function()'' luaBinds
        && lib.hasInfix ''hl.timer(function()'' luaBinds
        && !lib.hasInfix ''fkey_handler.sh'' luaBinds;
      message = "Lua workspace binds must support no-focus remote switching from the number row and F-keys without the legacy shell handler.";
    }
    {
      assertion =
        lib.hasInfix ''workspace = "special:special"'' hostLuaConfig
        && lib.hasInfix ''gaps_in = 0'' hostLuaConfig
        && lib.hasInfix ''gaps_out = 0'' hostLuaConfig
        && lib.hasInfix ''border_size = 0'' hostLuaConfig
        && lib.hasInfix ''name = "shared-special-workspace-opaque"'' hostLuaConfig
        && lib.hasInfix ''match = { workspace = "name:special:special" }'' hostLuaConfig
        && lib.hasInfix ''opacity = "1.0 override 1.0 override 1.0 override"'' hostLuaConfig
        && lib.hasInfix "windowrule = opacity 1.0 override 1.0 override 1.0 override, match:workspace name:special:special" hostLegacyConfig
        && lib.hasInfix ''name = "moonlight-native-half-width"'' hostLuaConfig
        && lib.hasInfix ''class = "^com.moonlight_stream.Moonlight$"'' hostLuaConfig
        && lib.hasInfix ''scrolling_width = 0.5'' hostLuaConfig;
      message = "The shared special workspace must retain exact geometry and fully opaque windows in both Hyprland configs.";
    }
    {
      assertion =
        !config.programs.hyprland.managed.liveConfigEditing
        && lib.hasInfix ''os.getenv("HYPRLAND_CONFIG_DIR")'' luaConfig;
      message = "xyz must start Hyprland from an immutable session configuration instead of the mutable workspace.";
    }
    {
      assertion =
        lib.hasInfix ''explicit_column_widths = "0.25,0.333,0.5,0.666,1"'' luaConfig
        && lib.hasInfix ''workspace = "10"'' luaConfig
        && lib.hasInfix ''local frontend_viewport_widths = { 390, 430, 768, 900, 1024, 1280, 1440, 1920 }'' luaScrollingBinds
        && lib.hasInfix ''{ "SUPER + C", "center" }'' luaScrollingBinds
        && lib.hasInfix ''rawget(_G, "alc_scrolling_column_widths_by_monitor")'' luaScrollingBinds
        && lib.hasInfix ''["HDMI-A-1"] = { 0.5, 0.666, 1 }'' hostLuaConfig;
      message = "xyz must retain context-aware scrolling widths and focused-column centering.";
    }
    {
      assertion = lib.all (hyprConfig: !lib.hasInfix "Heroes of the Storm" hyprConfig) [
        legacyBinds
        luaBinds
        luaConfig
        hostLegacyConfig
        hostLuaConfig
      ];
      message = "Heroes-specific behavior must not become a static Hyprland rule.";
    }
  ];

  # Import the common Linux configuration
  imports = [
    "${configDir}/users/alc/linux/operator.nix"

    "${configDir}/modules/home-manager/programs/wayland-common/default.nix"
    "${configDir}/modules/home-manager/programs/hyprland/default.nix"
    "${configDir}/modules/home-manager/programs/niri/default.nix"
    "${configDir}/modules/home-manager/services/dms/default.nix"
    "${configDir}/modules/home-manager/services/hyprlock/default.nix"
    "${configDir}/modules/home-manager/services/waynergy/default.nix"
    "${configDir}/modules/home-manager/programs/foot/default.nix"

    "${configDir}/modules/home-manager/programs/rclone/cloud-sync.nix"

    "${configDir}/modules/home-manager/programs/ai/default.nix"
    "${configDir}/modules/home-manager/programs/moonlight-wolf-client/default.nix"
    "${configDir}/modules/home-manager/programs/umu-apps/default.nix"
    "${configDir}/modules/home-manager/programs/stashdb-pop/default.nix"

    "${configDir}/modules/home-manager/services/paperflow/default.nix"
    "${configDir}/modules/home-manager/services/paperless-filetype-index/default.nix"
    "${configDir}/modules/home-manager/services/devlog/default.nix"
    "${configDir}/modules/home-manager/services/jean/default.nix"
    "${configDir}/modules/home-manager/services/t3code/default.nix"

    inputs.hyprscratch.homeModules.default
  ];

  # ==================== XYZ-Specific Settings ====================

  home.packages =
    pkgsets.home.${hostRole.homePackageSet}
    ++ [
      closeActiveWindow
      droptermToggle
      mailWorkspace
      pkgs.paperweight
    ];

  # xyz is the canonical headless T3 environment. Keep both historical
  # desktop command names pointed at its web client so cached launchers and
  # compositor bindings cannot accidentally start a second local backend.
  home.file = {
    ".local/bin/t3code" = {
      executable = true;
      source = "${t3codeWebLauncher}/bin/t3code-web";
    };
    ".local/bin/t3code-desktop" = {
      executable = true;
      source = "${t3codeWebLauncher}/bin/t3code-web";
    };
  };

  # Override the package's Electron desktop entry with the canonical web
  # client. The Electron binary remains available from the package store for
  # explicit troubleshooting, but it is not part of the normal xyz workflow.
  xdg.desktopEntries.t3code = {
    name = "T3 Code (xyz)";
    comment = "Connect to the headless T3 Code service on xyz";
    icon = "t3code";
    exec = "${t3codeWebLauncher}/bin/t3code-web";
    categories = ["Development"];
    settings.TryExec = "${t3codeWebLauncher}/bin/t3code-web";
  };

  # Symlink configs directly to repo checkout for live editing
  xdg.configFile."ncspot/config.toml".source =
    config.lib.file.mkOutOfStoreSymlink "${configDir}/users/alc/configs/ncspot/config.toml";

  # XYZ-specific aliases
  home.shellAliases = {
    pbcopy = "wl-copy";
    pbpaste = "wl-paste";
    # Single-layer remote rebuilds (deploy <host> does both)
    nxsw-nux = "deploy --nixos nux";
    nxsw-nex = "deploy --nixos nex";
    nxsw-rpi0 = "deploy --nixos rpi0";
    nxsw-rpi1 = "deploy --nixos rpi1";
    nxsw-rpi2 = "deploy --nixos rpi2";
    nxsw-rpi3 = "deploy --nixos rpi3";
    hmsw-nux = "deploy --hm nux";
    hmsw-nex = "deploy --hm nex";
    hmsw-rpi0 = "deploy --hm rpi0";
  };

  # Enable XYZ-specific programs
  programs.foot.enable = true;
  programs.hyprland.managed = {
    enable = true;
    manageLegacyConfig = false;
    manageLuaConfig = true;
    liveConfigEditing = false;
    # Match the qualified couch cursor policy. KDE Connect and other absolute
    # pointer paths can be classified as touch input by the compositor, even
    # though they are used as mice inside a windowed Moonlight stream.
    remotePointerInactiveTimeout = 8;
    remotePointerHideOnTouch = false;
    # Keep the already-running hyprlang session complete during the one-time
    # Lua migration. Future sessions start from extraLuaConfig below.
    extraConfig = ''
      monitor = DP-1, 5120x1440@120, 0x1456, 1
      monitor = HDMI-A-1, modeline 241.50 2560 2608 2640 2720 1440 1443 1448 1481 +hsync -vsync, 1280x0, 1
      windowrule = opacity 1.0 override 1.0 override 1.0 override, match:workspace name:special:special
      bind = CTRL SHIFT, R, exec, moonlight-wolf-ui-lan
    '';
    extraLuaConfig = ''
      -- The secondary panel is physically 4K even though it runs at 1440p in
      -- this layout. Its useful scrolling widths start at half the output.
      alc_scrolling_column_widths_by_monitor = {
        ["HDMI-A-1"] = { 0.5, 0.666, 1 },
      }

      -- Center the secondary display above the primary ultrawide. Its EDID
      -- omits 1440p, so use a CVT reduced-blanking modeline to keep the iGPU's
      -- compositing load below the native 4K mode. The small logical gap acts
      -- as a soft pointer barrier for the auto-hiding bar.
      hl.monitor({ output = "DP-1", mode = "5120x1440@120", position = "0x1456", scale = 1 })
      hl.monitor({
        output = "HDMI-A-1",
        mode = "modeline 241.50 2560 2608 2640 2720 1440 1443 1448 1481 +hsync -vsync",
        position = "1280x0",
        scale = 1,
      })

      -- Two tiled columns on the 5120x1440 ultrawide must each retain an
      -- exact 2560x1440 content area. Any compositor gap forces Moonlight to
      -- resample its 1440p stream and visibly softens fine detail.
      hl.workspace_rule({
        workspace = "special:special",
        gaps_in = 0,
        gaps_out = 0,
        border_size = 0,
      })
      hl.window_rule({
        name = "shared-special-workspace-opaque",
        match = { workspace = "name:special:special" },
        opacity = "1.0 override 1.0 override 1.0 override",
      })

      -- Keep Moonlight tiled while giving its 2560x1440 stream an exact half
      -- of the ultrawide. Scope this to Moonlight instead of changing the
      -- scrolling layout's one-third default for every other window.
      hl.window_rule({
        name = "moonlight-native-half-width",
        match = { class = "^com.moonlight_stream.Moonlight$" },
        scrolling_width = 0.5,
      })

      hl.bind("CTRL + SHIFT + R", hl.dsp.exec_cmd("moonlight-wolf-ui-lan"))
    '';
  };
  programs.niri.managed.enable = true;
  programs.moonlightWolfClient = {
    enable = true;
    videoCodec = "H.264";
    bitrateKbps = 60000;
    public = {
      enable = true;
      videoCodec = "H.264";
      bitrateKbps = 60000;
    };
  };
  programs.umuApps = {
    enable = true;
    apps = {
      battle-net = {
        displayName = "Battle.net";
        comment = "Launch Battle.net directly through UMU";
        icon = toString battleNetIcon;
        prefix = battleNetPrefix;
        executable = "${battleNetPrefix}/pfx/drive_c/Program Files (x86)/Battle.net/Battle.net.exe";
        protonPackage = protonGe10_4;
        environment = battleNetEnvironment;
      };
      heroes-profile = {
        displayName = "Heroes Profile";
        comment = "Launch the Heroes Profile uploader in the Battle.net compatibility prefix";
        icon = toString heroesProfileIcon;
        prefix = battleNetPrefix;
        executable = "${battleNetPrefix}/pfx/drive_c/users/steamuser/AppData/Local/Heroesprofile/Heroesprofile.Uploader.exe";
        protonPackage = protonGe10_4;
        role = "companion";
        environment = battleNetEnvironment;
      };
    };
  };

  programs.hyprscratch = {
    enable = true;
    settings = {
      daemon_options = "clean";

      dropterm = {
        title = "dropterm";
        command = "foot -w 2400x1400 --app-id dropterm --title dropterm";
        rules = "float; center";
        options = "persist";
      };
    };
  };

  # The upstream service follows a synthetic hyprland-session target which
  # stays active across UWSM compositor restarts. Bind it to the real WM unit
  # so it cannot retain a dead Hyprland event socket after a session restart.
  systemd.user.services.hyprscratch = {
    Unit = {
      BindsTo = ["wayland-wm@hyprland.desktop.service"];
      After = ["wayland-wm@hyprland.desktop.service"];
    };
    Install.WantedBy = ["wayland-wm@hyprland.desktop.service"];
  };

  services.dms.enable = true;
  services.dms.autoDoNotDisturb = {
    enable = true;
    windowMatchers = gamingWindowMatchers;
  };
  services.dms.settings = {
    audioVisualizerEnabled = false;
    scrollTitleEnabled = false;
    waveProgressEnabled = false;
  };
  services.dms.idleLock = {
    enable = true;
    command = config.services.hyprlock.lockCommand;
    acMonitorTimeout = 360;
    batteryMonitorTimeout = 0;
    respectExternalInhibitors = true;
  };
  services.dms.pluginSettings.dankAIUsage.enabled = true;
  services.hyprlock = {
    enable = true;
    turnOffDisplaysOnLock = true;
    displayOffDelay = 360;
  };
  systemd.user.services.hyprland-xwayland-primary-output = {
    Unit = {
      Description = "Maintain the 49-inch display as XWayland primary";
      PartOf = ["graphical-session.target"];
      After = ["graphical-session.target"];
    };
    Service = {
      Type = "simple";
      ExecStart = lib.getExe xwaylandPrimaryOutput;
      Restart = "on-failure";
      RestartSec = 1;
    };
    Install.WantedBy = ["graphical-session.target"];
  };
  systemd.user.services.hyprland-game-window-geometry-guard = {
    Unit = {
      Description = "Repair off-monitor game windows after output changes";
      BindsTo = ["wayland-wm@hyprland.desktop.service"];
      After = ["wayland-wm@hyprland.desktop.service"];
    };
    Service = {
      Type = "simple";
      ExecStart = lib.getExe gameWindowGeometryGuard;
      Restart = "on-failure";
      RestartSec = 1;
    };
    Install.WantedBy = ["wayland-wm@hyprland.desktop.service"];
  };
  services.waynergy = {
    enable = true;
    screenName = "xyz";
    sourceKeyboard = "mac";
    requireLanAddress = true;
  };
  services.kdeconnect.enable = true;
  # Hyprland's portal does not provide RemoteDesktop. Run KDE Connect through
  # XWayland so phone pointer and keyboard events use XTest instead of evdev;
  # this also keeps them entirely outside Kanata's device-grab path.
  systemd.user.services.kdeconnect.Service = let
    defaults = import "${configDir}/modules/shared/kdeconnect-input.nix";
    hyprlandInput =
      pkgs.callPackage "${configDir}/modules/nixos/services/kdeconnect-hyprland-input"
      {};
  in {
    Type = "dbus";
    BusName = "org.kde.kdeconnect";
    Environment = [
      "QT_QPA_PLATFORM=xcb"
      "KDECONNECT_SCROLL_INTERVAL_MS=${toString defaults.scrollIntervalMs}"
      "KDECONNECT_POINTER_SENSITIVITY=${toString defaults.pointerSensitivity}"
      "KDECONNECT_POINTER_PRECISION_SENSITIVITY=${toString defaults.pointerPrecisionSensitivity}"
      "KDECONNECT_POINTER_ACCELERATION_START=${toString defaults.pointerAccelerationStart}"
      "KDECONNECT_POINTER_ACCELERATION_FULL=${toString defaults.pointerAccelerationFull}"
      "LD_PRELOAD=${hyprlandInput}/lib/libkdeconnect-hypr-pointer-shim.so"
    ];
    Restart = lib.mkForce "on-failure";
  };
  systemd.user.services.kdeconnect-hypr-pointer = let
    hyprlandInput =
      pkgs.callPackage "${configDir}/modules/nixos/services/kdeconnect-hyprland-input"
      {};
  in {
    Unit = {
      Description = "KDE Connect Hyprland pointer bridge";
    };
    Service = {
      ExecStart = lib.getExe hyprlandInput;
      Restart = "always";
      RestartSec = 1;
    };
    Install.WantedBy = ["default.target"];
  };
  # The package's stock D-Bus service starts a second unmanaged daemon. Route
  # activation to the supervised XWayland unit instead.
  xdg.dataFile."dbus-1/services/org.kde.kdeconnect.service".text = ''
    [D-BUS Service]
    Name=org.kde.kdeconnect
    Exec=${pkgs.systemd}/bin/systemctl --user start kdeconnect.service
    SystemdService=kdeconnect.service
  '';
  services.udiskie = {
    enable = true;
    tray = "never";
  };
  systemd.user.services.udiskie = {
    Unit = {
      After = lib.mkForce [];
      PartOf = lib.mkForce [];
    };
    Install.WantedBy = lib.mkForce ["default.target"];
  };

  services.devlog.enable = true;
  services.devlog.weekly.enable = true;

  services.t3code = {
    enable = true;
    port = 3773;
    autoUpdate = {
      packageFlakeUri = "git+https://git.alc.xyz/alcxyz/nix-packages.git?ref=dev";
      promotionFlakeUri = "git+https://git.alc.xyz/alcxyz/nix-config.git?ref=dev";
      calendar = lib.mkForce "*-*-* 09:30:00";
      randomizedDelaySec = lib.mkForce "0";
    };
  };

  programs.ai.enable = true;
  programs.stashdb-pop.enable = true;

  services.cloud-sync = {
    enable = true;
    syncInterval = "15m";

    googleDrive = {
      enable = true;
      remote = "gdrive";
      localPath = "${config.home.homeDirectory}/Cloud/GoogleDrive";
    };

    dropbox = {
      enable = true;
      remote = "dropbox";
      localPath = "${config.home.homeDirectory}/Cloud/Dropbox";
    };
  };
}
