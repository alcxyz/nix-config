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
  xwaylandPrimaryOutput = pkgs.writeShellApplication {
    name = "hyprland-xwayland-primary-output";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.hyprland
      pkgs.jq
      pkgs.socat
      pkgs.util-linux
      pkgs.xrandr
    ];
    text = ''
      exec 9>"''${XDG_RUNTIME_DIR:?}/hyprland-xwayland-primary-output.lock"
      flock -n 9 || exit 0

      repair_primary() {
        stable_samples=0

        for _ in $(seq 1 20); do
        # XRandR queries can wake the HDMI output while the compositor has it
        # in DPMS-off. Leave XWayland completely untouched until every enabled
        # Hyprland output is awake again.
        if ! hyprctl monitors all -j 2>/dev/null \
          | jq -e 'length > 0 and all(.[]; .disabled or .dpmsStatus)' >/dev/null; then
            stable_samples=0
            sleep 0.25
          continue
        fi

        outputs="$(DISPLAY="''${DISPLAY:-:0}" xrandr --query 2>/dev/null || true)"

        if grep -q '^DP-1 connected primary ' <<<"$outputs"; then
            return 0
        elif grep -q '^DP-1 connected ' <<<"$outputs"; then
            stable_samples=$((stable_samples + 1))

          # Require two stable samples after hotplug. XWayland rebuilds its
          # RandR output list while the OLED reconnects and can otherwise clear
          # a primary assignment made during that transition.
            if ((stable_samples >= 2)); then
              DISPLAY="''${DISPLAY:-:0}" xrandr --output DP-1 --primary
              return
          fi
        else
            stable_samples=0
        fi

          sleep 0.25
        done

        echo "Failed to mark DP-1 as the XWayland primary output" >&2
        return 1
      }

      repair_primary || true

      socket="''${XDG_RUNTIME_DIR:?}/hypr/''${HYPRLAND_INSTANCE_SIGNATURE:?}/.socket2.sock"
      while true; do
        while IFS= read -r event; do
          case "$event" in
            monitoradded\>\>* | monitoraddedv2\>\>*) repair_primary || true ;;
          esac
        done < <(socat -U - UNIX-CONNECT:"$socket" 2>/dev/null)

        sleep 1
      done
    '';
  };
  centeredFloatToggle = pkgs.writeShellApplication {
    name = "hyprland-toggle-floating-centered";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
    ];
    text = ''
      client_json="$(hyprctl activewindow -j)"
      address="$(jq -r '.address // empty' <<<"$client_json")"

      if [[ ! "$address" =~ ^0x[0-9a-fA-F]+$ ]]; then
        echo "No active Hyprland window" >&2
        exit 1
      fi

      provider="$(hyprctl status -j | jq -r '.configProvider // empty')"
      if [[ "$provider" == lua ]]; then
        hyprctl eval \
          "hl.dispatch(hl.dsp.window.float({ action = \"toggle\", window = \"address:$address\" }))" \
          >/dev/null
      else
        hyprctl dispatch togglefloating >/dev/null
      fi

      # XWayland exposes the vertically stacked outputs to clients as one
      # horizontal strip. Wine games can consequently restore a floating
      # geometry centered on the synthetic boundary between those outputs.
      # Once the toggle has settled, center a newly floating window using the
      # compositor's real monitor coordinates instead.
      sleep 0.05
      if hyprctl clients -j \
        | jq -e --arg address "$address" \
            '.[] | select(.address == $address and .floating)' >/dev/null; then
        if [[ "$provider" == lua ]]; then
          hyprctl eval \
            "hl.dispatch(hl.dsp.window.center({ window = \"address:$address\" }))" \
            >/dev/null
        else
          hyprctl dispatch centerwindow >/dev/null
        fi
      fi
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
in {
  assertions = let
    legacyBinds = builtins.readFile "${configDir}/users/alc/configs/hypr/binds.conf";
    luaBinds = builtins.readFile "${configDir}/users/alc/configs/hypr/binds.lua";
    hostLegacyConfig = config.programs.hyprland.managed.extraConfig;
    hostLuaConfig = config.programs.hyprland.managed.extraLuaConfig;
  in [
    {
      assertion = lib.all (rule: lib.hasInfix rule legacyBinds) [
        "windowrule = no_focus on, match:class ^steam_app_default$, match:title ^TrackerWindow$"
        "windowrule = float on, match:class ^steam_app_default$, match:title ^Heroes of the Storm$"
        "windowrule = suppress_event maximize, match:class ^steam_app_default$, match:title ^Heroes of the Storm$"
      ];
      message = "The legacy Hyprland config must retain the Heroes floating/maximize regression rules.";
    }
    {
      assertion = lib.all (rule: lib.hasInfix rule luaBinds) [
        ''name = "battle-net-tracker-no-focus"''
        ''name = "heroes-floating"''
        ''title = "^Heroes of the Storm$"''
        ''suppress_event = "maximize"''
      ];
      message = "The Lua Hyprland config must retain the Heroes floating/maximize regression rule.";
    }
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
        lib.hasInfix ''move = "840 1456"'' hostLuaConfig
        && lib.hasInfix ''hl.on("window.open", settle_heroes_window)'' hostLuaConfig
        && lib.hasInfix ''hl.on("window.title", settle_heroes_window)'' hostLuaConfig
        && lib.hasInfix ''hl.on("monitor.layout_changed", settle_heroes_after_monitor_reconnect)'' hostLuaConfig
        && lib.hasInfix ''hl.timer(function()'' hostLuaConfig
        && !lib.hasInfix ''hl.dsp.focus'' hostLuaConfig
        && !lib.hasInfix ''center = true'' hostLuaConfig
        && lib.hasInfix "windowrule = move 840 1456, match:class ^steam_app_default$, match:title ^Heroes of the Storm$" hostLegacyConfig
        && !lib.hasInfix "windowrule = center on, match:class ^steam_app_default$, match:title ^Heroes of the Storm$" hostLegacyConfig;
      message = "Heroes must use fixed compositor coordinates and a focus-neutral event settle; XWayland-relative centering is unsafe after DPMS reconnects.";
    }
    {
      assertion =
        lib.hasInfix ''workspace = "special:special"'' hostLuaConfig
        && lib.hasInfix ''gaps_in = 0'' hostLuaConfig
        && lib.hasInfix ''gaps_out = 0'' hostLuaConfig
        && lib.hasInfix ''border_size = 0'' hostLuaConfig
        && lib.hasInfix ''name = "moonlight-native-half-width"'' hostLuaConfig
        && lib.hasInfix ''class = "^com.moonlight_stream.Moonlight$"'' hostLuaConfig
        && lib.hasInfix ''scrolling_width = 0.5'' hostLuaConfig;
      message = "The shared special workspace must retain zero gaps and borders so two tiled windows are exact 2560x1440 halves of DP-1.";
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
    "${configDir}/modules/home-manager/programs/stashdb-pop/default.nix"

    "${configDir}/modules/home-manager/services/paperflow/default.nix"
    "${configDir}/modules/home-manager/services/paperless-filetype-index/default.nix"
    "${configDir}/modules/home-manager/services/devlog/default.nix"
    "${configDir}/modules/home-manager/services/t3code/default.nix"

    inputs.hyprscratch.homeModules.default
  ];

  # ==================== XYZ-Specific Settings ====================

  home.packages =
    pkgsets.home.${hostRole.homePackageSet}
    ++ [
      droptermToggle
      pkgs.paperweight
    ];

  # Keep launchers with cached pre-0.0.32 desktop commands working after the
  # upstream executable was renamed from t3code to t3code-desktop. DMS stores
  # the old arguments in its usage history, so discard the obsolete sandbox
  # flag and any unexpanded desktop-entry URL placeholders.
  home.file.".local/bin/t3code" = {
    executable = true;
    text = ''
      #!${pkgs.runtimeShell}
      filtered=()
      for arg in "$@"; do
        case "$arg" in
          --no-sandbox|%u|%U) ;;
          *) filtered+=("$arg") ;;
        esac
      done
      exec ${pkgs.t3code}/bin/t3code-desktop "''${filtered[@]}"
    '';
  };

  # DMS can retain the package entry's former bare command across upgrades.
  # Prefer a user entry with an immutable executable path.
  xdg.desktopEntries.t3code = {
    name = "T3 Code (Alpha)";
    comment = "Minimal web GUI for coding agents";
    icon = "t3code";
    # T3 Code does not currently consume files or URLs, and DMS can pass an
    # unexpanded %U placeholder through as an application argument.
    exec = "${pkgs.t3code}/bin/t3code-desktop";
    categories = ["Development"];
    settings.TryExec = "${pkgs.t3code}/bin/t3code-desktop";
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
      # Heroes recreates its XWayland window when its display mode changes and
      # can reassert EWMH fullscreen during that remap. Keep the game in the
      # intended ultrawide window independently of its client hint. Use the
      # compositor coordinate explicitly: `center` can resolve against
      # XWayland's temporary horizontal RandR layout after DPMS reconnects.
      windowrule = suppress_event fullscreen, match:class ^steam_app_default$, match:title ^Heroes of the Storm$
      windowrule = sync_fullscreen off, match:class ^steam_app_default$, match:title ^Heroes of the Storm$
      windowrule = size 3440 1440, match:class ^steam_app_default$, match:title ^Heroes of the Storm$
      windowrule = move 840 1456, match:class ^steam_app_default$, match:title ^Heroes of the Storm$
      unbind = SUPER, S
      bind = SUPER, S, exec, ${lib.getExe centeredFloatToggle}
      bind = CTRL SHIFT, R, exec, moonlight-wolf-ui-lan
    '';
    extraLuaConfig = ''
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

      -- Keep Moonlight tiled while giving its 2560x1440 stream an exact half
      -- of the ultrawide. Scope this to Moonlight instead of changing the
      -- scrolling layout's one-third default for every other window.
      hl.window_rule({
        name = "moonlight-native-half-width",
        match = { class = "^com.moonlight_stream.Moonlight$" },
        scrolling_width = 0.5,
      })

      hl.window_rule({
        name = "heroes-centered-ultrawide",
        match = {
          class = "^steam_app_default$",
          title = "^Heroes of the Storm$",
          xwayland = true,
        },
        suppress_event = "fullscreen",
        sync_fullscreen = false,
        size = "3440 1440",
        move = "840 1456",
      })

      -- Static window effects are evaluated when a window first maps, using
      -- its initial X11 identity. Wine assigns the final Heroes title later
      -- and can issue another ConfigureWindow request after the static size
      -- and move, especially after XWayland rebuilt RandR during DPMS. React
      -- to the final title and reassert the intended geometry for a bounded
      -- launch-settle period. This never changes keyboard or pointer focus.
      local heroes_settling = {}
      local heroes_settle_timers = {}

      local function is_heroes_window(window)
        return window ~= nil
          and window.mapped
          and window.xwayland
          and window.class == "steam_app_default"
          and window.title == "Heroes of the Storm"
      end

      local function apply_heroes_geometry(window)
        if not is_heroes_window(window) then
          return
        end

        hl.dispatch(hl.dsp.window.float({ action = "set", window = window }))
        hl.dispatch(hl.dsp.window.resize({ x = 3440, y = 1440, window = window }))
        hl.dispatch(hl.dsp.window.move({ x = 840, y = 1456, window = window }))
      end

      local function settle_heroes_window(window)
        if not is_heroes_window(window) then
          return
        end

        local address = window.address
        if heroes_settling[address] then
          return
        end

        heroes_settling[address] = 4
        apply_heroes_geometry(window)

        for _, timeout in ipairs({ 100, 300, 750, 1500 }) do
          local timer
          timer = hl.timer(function()
            apply_heroes_geometry(hl.get_window("address:" .. address))

            heroes_settling[address] = heroes_settling[address] - 1
            if heroes_settling[address] == 0 then
              heroes_settling[address] = nil
            end
            heroes_settle_timers[timer] = nil
          end, { timeout = timeout, type = "oneshot" })
          heroes_settle_timers[timer] = true
        end
      end

      hl.on("window.open", settle_heroes_window)
      hl.on("window.title", settle_heroes_window)

      local function settle_heroes_after_monitor_reconnect()
        local primary = hl.get_monitor("DP-1")
        local secondary = hl.get_monitor("HDMI-A-1")
        if primary == nil
          or secondary == nil
          or not primary.dpms_status
          or not secondary.dpms_status
        then
          return
        end

        for _, window in ipairs(hl.get_windows()) do
          settle_heroes_window(window)
        end
      end

      hl.on("monitor.layout_changed", settle_heroes_after_monitor_reconnect)

      hl.unbind("SUPER + S")
      hl.bind("SUPER + S", hl.dsp.exec_cmd("${lib.getExe centeredFloatToggle}"))
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
      Description = "Keep the 49-inch display primary in XWayland";
      PartOf = ["graphical-session.target"];
      After = ["graphical-session.target"];
    };
    Service = {
      ExecStart = lib.getExe xwaylandPrimaryOutput;
      Restart = "always";
      RestartSec = 2;
    };
    Install.WantedBy = ["graphical-session.target"];
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

  services.t3code.enable = false;
  services.t3code.port = 3773;

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
