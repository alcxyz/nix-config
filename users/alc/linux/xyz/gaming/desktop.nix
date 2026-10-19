# Fragments keep gaming rules in their existing position among shared desktop rules.
{
  lib,
  xwaylandPrimaryOutput,
  gameWindowGeometryGuard,
}: let
  gamingWindowMatchers = [
    {
      classRegex = "^steam_app_default$";
      titleRegex = "^Heroes of the Storm$";
    }
  ];
  # Launcher windows recover geometry without joining the game matchers, which
  # also drive notification suppression. Offsets are relative to the restore
  # monitor; the launcher size comes from its floating rule below.
  launcherGeometryPolicies = [
    {
      classRegex = "^steam_app_default$";
      titleRegex = "^Battle[.]net$";
      centerOnRecovery = true;
    }
    {
      # Wine's tray window for the launcher prefix.
      classRegex = "^steam_app_default$";
      titleRegex = "^$";
      homeOffset = {
        x = 16;
        y = 16;
      };
    }
  ];
in {
  windowMatchers = gamingWindowMatchers;
  inherit launcherGeometryPolicies;
  luaRules = lib.removeSuffix "\n" ''
    -- Launcher ecosystems use separate unpinned workspaces, not fixed
    -- outputs. Route only the Steam client; games remain opt-in by exact
    -- identity. Geometry, focus, fullscreen, and pointer behavior remain
    -- outside static rules, except the Battle.net launcher's floating size.
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
      -- A tiled column on a narrower output is below the launcher's minimum
      -- width. Wine and the layout then resize it against each other without
      -- end, so the launcher floats at a size that fits every output.
      float = true,
      size = "1600 1376",
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
      -- A monitor-height game plus decorations exceeds the work area.
      -- Floating workspace moves otherwise clamp it upward by the border.
      border_size = 0,
    })
  '';
  module = {
    services.dms.autoDoNotDisturb = {
      enable = true;
      windowMatchers = gamingWindowMatchers;
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
  };
}
