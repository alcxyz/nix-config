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
      snapFullHeight = true;
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
  desktopHelpers = import ./xyz/desktop-helpers.nix {
    inherit config lib pkgs gameWindowGeometryPolicies;
  };
  inherit (desktopHelpers) mailWorkspaceScript mailWorkspace closeActiveWindowScript closeActiveWindow xwaylandPrimaryOutput gameWindowGeometryGuard droptermToggle;
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
    legacyConfig = builtins.readFile "${configDir}/users/alc/configs/hypr/hyprland.conf";
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
        lib.hasInfix ''hl.bind("SUPER + B", hl.dsp.exec_cmd("zen --no-remote -profile /home/alc/.zen/alcxyz"))'' luaBinds
        && lib.hasInfix ''hl.bind("SUPER + V", hl.dsp.exec_cmd('helium --profile-directory="Profile 2"'))'' luaBinds
        && lib.hasInfix ''hl.bind("SUPER + X", hl.dsp.exec_cmd('helium --profile-directory="Profile 1" --remote-debugging-port=9222'))'' luaBinds
        && lib.hasInfix ''hl.bind("SUPER + Z", hl.dsp.exec_cmd('brave --profile-directory="Profile 1" --remote-debugging-port=9223'))'' luaBinds
        && lib.hasInfix ''hl.bind("SUPER + SHIFT + N", hl.dsp.exec_cmd("dms ipc call notifications open"))'' luaBinds
        && lib.hasInfix ''hl.bind("SUPER + O", hl.dsp.exec_cmd("dms ipc call hypr toggleOverview"))'' luaBinds
        && lib.hasInfix ''hl.bind("SUPER + N", hl.dsp.exec_cmd("dms ipc call notepad toggle"))'' luaBinds
        && lib.hasInfix ''bind = SUPER, V, exec, $helium --profile-directory="Profile 2"'' legacyBinds
        && lib.hasInfix ''bind = SUPER, X, exec, $helium --profile-directory="Profile 1" --remote-debugging-port=9222'' legacyBinds
        && lib.hasInfix ''bind = SUPER, Z, exec, $brave --profile-directory="Profile 1" --remote-debugging-port=9223'' legacyBinds
        && lib.hasInfix "bind = SUPER SHIFT, N, exec, dms ipc call notifications open" legacyBinds
        && lib.hasInfix "bind = SUPER, O, exec, dms ipc call hypr toggleOverview" legacyBinds
        && lib.hasInfix "bind = SUPER, N, exec, dms ipc call notepad toggle" legacyBinds
        && !lib.hasInfix ''hl.bind("SUPER + ALT + V",'' luaBinds
        && !lib.hasInfix ''hl.bind("SUPER + ALT + X",'' luaBinds
        && !lib.hasInfix ''hl.bind("SUPER + ALT + Z",'' luaBinds;
      message = "Browser and infrequent utility shortcuts must remain stable without consuming the Super+Alt movement layer.";
    }
    {
      assertion =
        lib.hasInfix ''hl.bind("SUPER + E", hl.dsp.focus({ workspace = 7 }))'' luaBinds
        && lib.hasInfix ''hl.bind("SUPER + SHIFT + E", hl.dsp.window.move({ workspace = 7 }))'' luaBinds
        && lib.hasInfix ''hl.bind("SUPER + ALT + E", hl.dsp.window.move({ workspace = 7, follow = false }))'' luaBinds
        && lib.hasInfix "bind = SUPER, E, workspace, 7" legacyBinds
        && lib.hasInfix "bind = SUPER SHIFT, E, movetoworkspace, 7" legacyBinds
        && lib.hasInfix "bind = SUPER ALT, E, movetoworkspacesilent, 7" legacyBinds
        && lib.hasInfix ''hl.bind("SUPER + G", hl.dsp.focus({ workspace = 8 }))'' luaBinds
        && lib.hasInfix ''hl.bind("SUPER + SHIFT + G", hl.dsp.window.move({ workspace = 8 }))'' luaBinds
        && lib.hasInfix ''hl.bind("SUPER + ALT + G", hl.dsp.window.move({ workspace = 8, follow = false }))'' luaBinds
        && lib.hasInfix "bind = SUPER, G, workspace, 8" legacyBinds
        && lib.hasInfix "bind = SUPER SHIFT, G, movetoworkspace, 8" legacyBinds
        && lib.hasInfix "bind = SUPER ALT, G, movetoworkspacesilent, 8" legacyBinds
        && lib.hasInfix ''workspace = "7"'' luaConfig
        && lib.hasInfix ''default_name = "steam"'' luaConfig
        && lib.hasInfix ''workspace = "8"'' luaConfig
        && lib.hasInfix ''default_name = "battle-net"'' luaConfig
        && lib.hasInfix "workspace = 7, defaultName:steam" legacyConfig
        && lib.hasInfix "workspace = 8, defaultName:battle-net" legacyConfig;
      message = "The unpinned Steam and Battle.net workspaces and their complete letter-based workspace shortcuts must remain declarative.";
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
      assertion =
        lib.all (hyprConfig: !lib.hasInfix "Heroes of the Storm" hyprConfig) [
          legacyBinds
          luaBinds
          luaConfig
        ]
        && lib.hasInfix ''name = "steam-client-workspace"'' hostLuaConfig
        && lib.hasInfix ''name = "battle-net-gaming-workspace"'' hostLuaConfig
        && lib.hasInfix ''name = "wine-desktop-gaming-workspace"'' hostLuaConfig
        && lib.hasInfix ''name = "heroes-gaming-workspace"'' hostLuaConfig
        && lib.hasInfix ''workspace = "8 silent"'' hostLuaConfig
        && lib.hasInfix "windowrule = workspace 7 silent, match:class ^steam$, match:xwayland true" hostLegacyConfig
        && lib.hasInfix "windowrule = workspace 8 silent, match:class ^steam_app_default$, match:title ^Battle[.]net$, match:xwayland true" hostLegacyConfig
        && lib.hasInfix "windowrule = workspace 8 silent, match:class ^steam_app_default$, match:title ^$, match:xwayland true" hostLegacyConfig
        && lib.hasInfix "windowrule = workspace 8 silent, match:class ^steam_app_default$, match:title ^Heroes of the Storm$, match:xwayland true" hostLegacyConfig
        && !lib.hasInfix ''suppress_event = "fullscreen"'' hostLuaConfig
        && !lib.hasInfix ''sync_fullscreen'' hostLuaConfig
        && !lib.hasInfix ''size = "3440 1440"'' hostLuaConfig
        && !lib.hasInfix ''move = "840 1456"'' hostLuaConfig;
      message = "Steam, Battle.net, its Wine desktop helper, and Heroes may use only static workspace routing; geometry, focus, fullscreen, and pointer repairs must remain event-scoped.";
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
      windowrule = workspace 7 silent, match:class ^steam$, match:xwayland true
      windowrule = workspace 8 silent, match:class ^steam_app_default$, match:title ^Battle[.]net$, match:xwayland true
      windowrule = workspace 8 silent, match:class ^steam_app_default$, match:title ^$, match:xwayland true
      windowrule = workspace 8 silent, match:class ^steam_app_default$, match:title ^Heroes of the Storm$, match:xwayland true
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

      -- Launcher ecosystems use separate unpinned workspaces, not fixed
      -- outputs. Route only the Steam client; games remain opt-in by exact
      -- identity. Geometry, focus, fullscreen, and pointer behavior remain
      -- outside static rules.
      hl.window_rule({
        name = "steam-client-workspace",
        match = {
          class = "^steam$",
          xwayland = true,
        },
        workspace = "7 silent",
      })
      hl.window_rule({
        name = "battle-net-gaming-workspace",
        match = {
          class = "^steam_app_default$",
          title = "^Battle[.]net$",
          xwayland = true,
        },
        workspace = "8 silent",
      })
      hl.window_rule({
        name = "wine-desktop-gaming-workspace",
        match = {
          class = "^steam_app_default$",
          title = "^$",
          xwayland = true,
        },
        workspace = "8 silent",
      })
      hl.window_rule({
        name = "heroes-gaming-workspace",
        match = {
          class = "^steam_app_default$",
          title = "^Heroes of the Storm$",
          xwayland = true,
        },
        workspace = "8 silent",
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
        staleRecoveryWindowMatchers = [
          {
            classRegex = "^steam_app_default$";
            titleRegex = "^Battle[.]net$";
          }
          {
            classRegex = "^steam_app_default$";
            titleRegex = "^Heroes of the Storm$";
          }
        ];
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
  services.dms.dankSession = {
    enable = true;
    autoStart = true;
  };
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
  services.dms.pluginSettings.dankSession = {
    enabled = true;
    # Saving, restoration, frequency, and exclusions are user-owned in the UI.
    # Do not reset them to QA defaults during Home Manager activation.
  };
  services.hyprlock = {
    enable = true;
    turnOffDisplaysOnLock = true;
    displayOffDelay = 360;
  };
  systemd.user.services.hyprland-xwayland-primary-output = {
    Unit = {
      Description = "Maintain the 49-inch display as XWayland primary";
      BindsTo = ["wayland-wm@hyprland.desktop.service"];
      After = ["wayland-wm@hyprland.desktop.service"];
    };
    Service = {
      Type = "simple";
      ExecStart = lib.getExe xwaylandPrimaryOutput;
      Restart = "on-failure";
      RestartSec = 1;
    };
    Install.WantedBy = ["wayland-wm@hyprland.desktop.service"];
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
    channel = "fork"; # Select "upstream" to return to the upstream build.
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
