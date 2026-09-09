{
  closeActiveWindowScript,
  config,
  configDir,
  lib,
  mailWorkspaceScript,
}: {
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
      message = "The screen-saver key must use the normal lock-screen path in both Hyprland configs.";
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
}
